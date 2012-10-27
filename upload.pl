
use strict; use warnings;

use Data::Dumper;
use Getopt::Long;
use MIME::Base64 qw(encode_base64);

use AE;
use EV;
use AnyEvent::Log;

GetOptions(
    my $opts = {
        httpsverify => 0,
    },
    "username=s",
    "password=s",
    "httpsverify!",
);

AnyEvent::Log::ctx->level("info");
$AnyEvent::Log::FILTER->level("trace");

my @data_set = (
    ['GET', 'https://www.facebook.com/', undef, {Connection => 'close'}],
    #['GET', 'https://www.google.be/', undef, {Connection => 'close', 'Accept-Encoding' => 'gzip'}],
    #['GET', 'http://localhost:8080/', undef, {Connection => 'close', 'Accept-Encoding' => 'gzip'}],
    #['PUT', '/def', encode_json([{abctest => 1}]), {}],
);

my $data_sent = 0;
my $orig_set_size = scalar(@data_set);
my @handles;
while(@data_set){
    my $cv = \AE::cv();
    while(scalar(@handles) < 1 and @data_set){
        AE::log info => "NEW:".scalar(@handles);
        my $hdl = AE::HTTP->new({
            # producer
            producer => sub {
                AE::log info => "SEND:".scalar(@data_set);
                my $r = shift @data_set;
                AE::log info => "SEND:".Dumper($r);
                return $r;
            },
            # consumer
            consumer => sub {
                my ($response) = @_;
                AE::log info => "RESPONSE:".scalar(@data_set);
                $data_sent++;
                AE::log info => "OK:$data_sent, $orig_set_size, responsebody:".($response//'<undef>');
                print $response if defined $response;
                if(scalar(@data_set) == 0 and $data_sent == $orig_set_size){
                    AE::log info => "END OK:$data_sent, $orig_set_size, ".scalar(@data_set);
                    ${$cv}->send();
                }
            },
            # error: put back in queue
            error_handler => sub {
                unshift @data_set, $_[0];
            },
            # condvar
            cv => $cv,
            # default headers stuff, can be overridden with individual
            # requests
            headers    => {
                "Host"            => "localhost",
                "User-Agent"      => "SomeClientSpeedTest/1.0",
                (($opts->{username} and $opts->{password})?
                    ("Authorization" => "Basic ".encode_base64("$opts->{username}:$opts->{password}", '')):()),
                "Connection"      => 'Keep-Alive',
            },
            # config to handle https
            tls_ctx    => {
                method => 'SSLv3',
                verify => $opts->{httpsverify} // 0,
            },
        });
        push @handles, $hdl;
    }
    AE::log info => "WAIT:".scalar(@handles);
    $$cv->recv();
    @handles = grep {!$_->{hdl}->destroyed()} @handles;
    AE::log info => "LOOP:".scalar(@handles);
}
AE::log info => "LOOP END:".scalar(@handles);

package AE::HTTP;

use strict; use warnings;

use URI;
use Errno;
use IO::Socket::SSL;
use Compress::Zlib;
use Data::Dumper;

use AnyEvent::Socket;
use AnyEvent::Handle;
use AnyEvent::Log;




sub new {
    my ($class, $state) = @_;

    # get an entry
    schedule_next($state);

    # make the handle
    my $hdl = new AnyEvent::Handle(
        connect => [$state->{request_host}, $state->{request_port}],
        ($state->{request_protocol} eq 'https'?(
            tls_ctx => $state->{tls_ctx},
            tls     => 'connect'
        ):()),
        on_connect => sub {
            my ($hdl, $host, $port, undef) = @_;
            AE::log info => "CONNECT:$hdl->{peername},$host:$port";
        }
    );
    $state->{hdl} = $hdl;
    $hdl->on_read(sub {
        my ($hdl) = @_;
        AE::log debug => "on_read() called";
        &{$state->{request_cb}}($state);
    });
    my $disconnect = sub {
        my ($hdl, $fatal, $msg) = @_;
        $hdl->destroy();
        if(($state->{response_headers}{Connection} // '') eq 'close'){
            &{$state->{consumer}}(delete $state->{current_data_body});
            #_init($state);
        }
        ${$state->{cv}}->send();
    };
    $hdl->on_error(sub {
        my ($hdl, $fatal, $msg) = @_;
        AE::log error => $msg;
        &$disconnect(@_);
    });
    $hdl->on_eof($disconnect);
    $hdl->on_drain(sub {
        my ($hdl) = @_;
        &{$state->{next_cb}}($state);
    });

    return bless $state, ref($class)||$class;
}

sub send_data {
    my ($self) = @_;
    my $str = substr($self->{request_data}, 0, 10_000_000, '');
    unless (length($str)){
        $self->{next_cb} = \&schedule_next;
        $self->{hdl}->on_drain(undef);
        return 0;
    }
    return 1;
}

sub get_next {
    my ($self) = @_;
    my $data = &{$self->{producer}}();
    unless(defined $data){
        return;
    }
    my $uri = URI->new($data->[1]);
    AE::log info => "$data->[0] ".$uri->as_string();
    #$uri->query_form(map {$_, $params->{$_}} grep {defined $params->{$_}} keys %{$params});
    return $data->[0], $data->[2], $uri->host(), $uri->port(), $uri->scheme(), $uri->as_string(), $data->[3];
}

sub schedule_next {
    my ($self) = @_;
    my ($method, $body, $host, $port, $scheme, $path, $headers) = get_next($self);
    unless($method){
        ${$self->{cv}}->send();
        return 0;
    }

    # start new
    $self->{request_cb}      = \&read_response_status;
    $self->{next_cb}         = \&send_request;
    $self->{request_method}  = $method;
    $self->{request_data}    = $body // '';
    $self->{request_headers} = $headers;
    $self->{request_host}    = $host;
    $self->{request_port}    = $port;
    $self->{request_protocol}= $scheme;
    $self->{request_path}    = $path;
    delete @{$self}{qw(
        size_wanted
        response_headers
        current_data_body
        current_chunk
        chunk_wanted_size
        response_status_code
        response_status_message
    )};
    AE::log debug => "schedule_next: $method $host $path";
    return 1;
}

sub send_request {
    my ($self) = @_;
    $self->{next_cb} = \&send_data;

    my %hdr = (%{$self->{headers}}, %{$self->{request_headers}//{}});
    $hdr{'content-length'} = length($self->{request_data});
    my $buf = "$self->{request_method} $self->{request_path} HTTP/1.1\r\n"
         . join('', map "\u$_: $hdr{$_}\r\n", grep defined $hdr{$_}, keys %hdr)
         . "\r\n";
    AE::log debug => "send_request: $buf";
    $self->{hdl}->push_write($buf);
    return 0;
}

sub read_response_status {
    my ($self) = @_;
    AE::log debug => "read_response_status:".$self->{hdl}->rbuf;
    $self->{hdl}->rbuf =~ s/^\r\n//;
    if ($self->{hdl}->rbuf =~ s/^HTTP\/1\.1 (\d+) (.*?)\r\n//){
        my ($code, $msg) = ($1, $2);
        $self->{response_status_code}    = $code;
        $self->{response_status_message} = $msg;
        AE::log info => "RESPONSE OK:$code, $msg";
        $self->{request_cb} = \&read_response_headers;
        return 1;
    }
    return 0;
}

sub read_response_headers {
    my ($self) = @_;
    my $hdl = $self->{hdl};
    AE::log debug => "read_response_headers:".$hdl->rbuf;
    if ($hdl->rbuf =~ s/^(.*?)\r\n//){
        my $line = $1;
        AE::log debug => "read_response_headers (line):".$line;
        if(length($line) == 0){
            my $rh = $self->{response_headers};
            AE::log debug => Dumper($rh);
            my $chunked = ($rh->{"Transfer-Encoding"}//'') =~ /\bchunked\b/i;
            my $len = $chunked ? undef : $rh->{"Content-Length"};
            if(defined $len){
                $self->{size_wanted} = $len;
                $self->{request_cb}  = \&body_reader;
            } else {
                if($chunked){
                    $self->{request_cb} = \&chunked_body_reader;
                } else {
                    $self->{request_cb} = \&body_reader;
                }
            }
        } else {
            if(my ($h, $v) = ($line =~ m/^(.*?): (.*)/)){
                $self->{response_headers}{$h} = $v;
                return length($hdl->rbuf);
            }
            return 0;
        }
        return length($hdl->rbuf);
    }
    return 0;
}

sub body_reader {
    my ($self) = @_;
    my $hdl = $self->{hdl};
    my $size = $self->{size_wanted};
    if(defined $size){
        my $size_todo = $size - length($self->{current_data_body}//'');
        $self->{current_data_body} .= substr($hdl->{rbuf}, 0, $size_todo, '');
        if(length($self->{current_data_body}) >= $size){
            &{$self->{consumer}}(delete $self->{current_data_body});
            _init($self);
            return length($hdl->rbuf);
        }
    } else {
        $self->{current_data_body} .= delete $hdl->{rbuf};
        return 0;
    }
    return 0;
}

sub chunk_reader {
    my ($self) = @_;
    my $hdl = $self->{hdl};
    my $size = $self->{chunk_wanted_size};
    AE::log debug => "CHUNK>>$size>>".$hdl->rbuf;
    my $size_todo = $size - length($self->{current_chunk}//'');
    $self->{current_chunk} .= substr($hdl->{rbuf}, 0, $size_todo, '');
    if(length($self->{current_chunk}) >= $size){
        $self->{current_data_body} .= delete $self->{current_chunk};
        $self->{request_cb} = \&chunked_body_reader;
        return length($hdl->rbuf);
    }
    AE::log debug => "LEFTCHUNK>>".$hdl->rbuf;
    return 0;
}

sub chunked_body_reader {
    my ($self) = @_;
    my $hdl = $self->{hdl};
    AE::log debug => "CHUNKBODYREADER>>".$hdl->rbuf;
    if($hdl->rbuf =~ s/^\r\n//){
        return length($hdl->rbuf);
    }
    if($hdl->rbuf =~ s/^([0-9A-Fa-f]+?)\r\n//){
        my $size = hex($1);
        AE::log debug => "chunk size: hex($1) = $size";
        if($size){
            $self->{chunk_wanted_size} = $size;
            $self->{request_cb} = \&chunk_reader;
        } else {
            &{$self->{consumer}}(delete $self->{current_data_body});
            _init($self);
        }
        return length($hdl->rbuf);
    }
    return 0;
}

sub _init {
    my ($self) = @_;
    my $hdl = $self->{hdl};
    schedule_next($self);
    $hdl->on_drain(sub {
        my ($hdl) = @_;
        AE::log debug => "_init(): called next_cb";
        &{$self->{next_cb}}($self);
    });
}

