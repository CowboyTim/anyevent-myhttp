
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
    "header|h=s%",
    "httpsverify!",
);

AnyEvent::Log::ctx->level("info");
$AnyEvent::Log::FILTER->level("trace");

my @data_set = (
    #['GET', 'http://www.browserscope.org/', undef, {Connection => 'close', 'Accept-Encoding' => 'gzip'}],
    #['GET', 'http://www.facebook.com/', undef, {Connection => 'close'}],
    #['GET', 'http://www.deredactie.be/', undef, {Connection => 'close', }],
    #['GET', 'https://www.google.be/', undef, {Connection => 'close'}],
    ['GET', 'https://www.google.com/', undef, {Connection => 'close'}],
    #['GET', 'https://www.google.com/', undef, {}],
    #['GET', 'https://www.google.be/', undef, {}],
    #['GET', 'https://www.google.be/', undef, {Connection => 'close', 'Accept-Encoding' => 'gzip'}],
    #['GET', 'http://localhost:8080/', undef, {Connection => 'close', 'Accept-Encoding' => 'gzip'}],
    #['PUT', '/def', encode_json([{abctest => 1}]), {}],
);

my $data_sent = 0;
my $orig_set_size = scalar(@data_set);
my @handles;
while(@data_set){
    my $cv = \AE::cv();
    while(scalar(@handles) < 2 and @data_set){
        AE::log info => "NEW:".scalar(@handles);
        my $hdl = AE::HTTP->new({
            requests => \@data_set,
            # producer
            producer => sub {
                AE::log info => "SEND:".scalar(@data_set);
                my $r = shift @data_set;
                AE::log info => "SEND:".Dumper($r);
                return $r;
            },
            # consumer
            consumer => sub {
                my ($code, $msg, $body, $headers) = @_;
                AE::log info => "CONSUMER LEFT:".scalar(@data_set);
                $data_sent++;
                AE::log info =>
                    "OK:$data_sent, $orig_set_size, ".
                    "response body:".($body//'<undef>').", status: $code, msg: ".($msg//'');
                print $body if defined $body;
                if(scalar(@data_set) == 0 and $data_sent == $orig_set_size){
                    AE::log info => "END OK:$data_sent, $orig_set_size, ".scalar(@data_set);
                    ${$cv}->send();
                }
            },
            # condvar
            cv => $cv,
            # default headers stuff, can be overridden with individual
            # requests
            headers    => {
                "User-Agent"      => "SomeClientSpeedTest/1.0",
                (($opts->{username} and $opts->{password})?
                    ("Authorization" => "Basic ".encode_base64("$opts->{username}:$opts->{password}", '')):()),
                "Connection"      => 'Keep-Alive',
                %{$opts->{header}//{}}
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
    AE::log info => "LOOP:".scalar(@handles).",DATA_SET:".scalar(@data_set);
}
AE::log info => "LOOP END:".scalar(@handles);

package AE::HTTP;

use strict; use warnings;

use URI;
use Data::Dumper;
use IO::Uncompress::Gunzip qw(gunzip);

use AnyEvent::Socket;
use AnyEvent::Handle;
use AnyEvent::Log;

sub new {
    my ($class, $state) = @_;

    my $self = bless $state, ref($class)||$class;

    # get an entry
    $self->schedule_next();

    # make the handle
    my $uri = $self->{uri};
    my $hdl = new AnyEvent::Handle(
        connect => [$uri->host(), $uri->port()],
        ($uri->scheme() eq 'https'?(
            tls_ctx => $self->{tls_ctx},
            tls     => 'connect'
        ):()),
        on_connect => sub {
            my ($hdl, $host, $port, undef) = @_;
            AE::log info => "CONNECT:$hdl->{peername},$host:$port";
        }
    );
    $self->{hdl} = $hdl;
    $hdl->on_read(sub {
        my ($hdl) = @_;
        AE::log debug => "on_read() called";
        &{$self->{request_cb}}($self);
    });
    my $disconnect = sub {
        my ($hdl, $fatal, $msg) = @_;
        AE::log info => "DISCONNECT";
        $hdl->destroy();

        # 'close' Connections that have no Content-Length set will just
        # disconnect instead of letting the condition be true in
        # body_reader(), hence we do a consume_next(). *Sigh* HTTP
        # sucks.
        if(($self->{response_headers}{Connection} // '') eq 'close'){
            $self->consume_next();
        }
        ${$self->{cv}}->send();
    };
    $hdl->on_error(sub {
        my ($hdl, $fatal, $msg) = @_;
        AE::log error => $msg;
        &$disconnect(@_);
    });
    $hdl->on_eof($disconnect);
    $hdl->on_drain(sub {
        my ($hdl) = @_;
        AE::log debug => "on_drain(): called next_cb";
        &{$self->{next_cb}}($self);
    });

    return $self;
}

sub consume_next {
    my ($self) = @_;
    my ($code, $msg, $body, $headers) = @{$self}{qw(
        response_status_code
        response_status_message
        current_data_body
        response_headers
    )};
    if(defined $code and $code eq '302'){
        AE::log info => "REDIRECT: $code ['GET', $headers->{Location}, undef, '<HEADERS>']";
        # redirect: make a new request at the start of the queue
        unshift @{$self->{requests}}, ['GET', $headers->{Location}, undef, $self->{request_headers}];
    } else {
        &{$self->{consumer}}($code, $msg, $body, $headers);
    }
}

sub get_next {
    my ($self) = @_;
    # delete the response headers, else a redirect ends up double when a
    # 'close' Connection happens because of the disconnect also doing a
    # consume_next().
    my $resp_headers = delete $self->{response_headers};

    # return when it was a 'close' Connection
    return if $resp_headers and ($resp_headers->{Connection} // '') eq 'close';

    # schedule next, make on_drain() produce data again!
    $self->schedule_next();
    $self->{hdl}->on_drain(sub {
        my ($hdl) = @_;
        AE::log debug => "on_drain(): called next_cb";
        &{$self->{next_cb}}($self);
    });
}

sub send_data {
    my ($self) = @_;
    my $str = substr($self->{request_data}, 0, 10_000_000, '');
    unless (length($str)){
        $self->{next_cb} = sub {$self->schedule_next()};
        $self->{hdl}->on_drain(undef);
        return 0;
    }
    return 1;
}

sub schedule_next {
    my ($self) = @_;
    my $data = &{$self->{producer}}();
    unless(defined $data){
        ${$self->{cv}}->send();
        return 0;
    }

    %{$self} = (
        producer => $self->{producer},
        consumer => $self->{consumer},
        requests => $self->{requests},
        cv       => $self->{cv},
        headers  => $self->{headers},
        tls_ctx  => $self->{tls_ctx},
        hdl      => $self->{hdl},
    );

    my $uri = URI->new($data->[1]);
    AE::log info => "$data->[0] ".$uri->as_string();
    #$uri->query_form(map {$_, $params->{$_}} grep {defined $params->{$_}} keys %{$params});

    # start new
    $self->{request_cb}      = \&read_response_status;
    $self->{next_cb}         = \&send_request;
    $self->{request_method}  = $data->[0];
    $self->{request_data}    = $data->[2] // '';
    $self->{request_headers} = $data->[3];
    $self->{uri}             = $uri;

    # add some headers
    $self->{request_headers}{'Content-Length'} = length($self->{request_data});
    $self->{request_headers}{'Host'}  = $uri->host();
    $self->{request_headers}{'Host'} .= ':'.$uri->port() if ($uri->port()//'') ne '80';

    AE::log debug => "schedule_next: ".$uri->as_string();
    return 1;
}

sub send_request {
    my ($self) = @_;
    $self->{next_cb} = \&send_data;

    my %hdr = (%{$self->{headers}}, %{$self->{request_headers}//{}});
    my $buf = join("\r\n",
        "$self->{request_method} ".$self->{uri}->as_string()." HTTP/1.1",
        (map {"\u$_: $hdr{$_}"} grep {defined $hdr{$_}} keys %hdr),
    )."\r\n\r\n";
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
        AE::log info => "RESPONSE: $code, $msg";
        $self->{response_status_code}    = $code;
        $self->{response_status_message} = $msg;
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

            # if chunked, use the chunked body reader, else just the
            # regular one
            my $chunked = ($rh->{"Transfer-Encoding"}//'') =~ /\bchunked\b/i;
            if(!$chunked){
                $self->{current_data_body} = '';
                $self->{size_gotten} = 0;
                $self->{size_wanted} = $rh->{"Content-Length"};
                $self->{request_cb}  = \&body_reader;
            } else {
                $self->{request_cb} = \&chunked_body_reader;
            }

            # add a uncompressor if wanted
            if($rh->{"Content-Encoding"} ~~ 'gzip'){
                my $dbuf = '';
                $self->{uncompress} = sub {
                    my ($buf, $input) = @_;
                    $dbuf .= $$input;
                    AE::log debug => Dumper($input);
                    gunzip(\$dbuf => \$self->{current_data_body}, TrailingData => \my $abc);
                    AE::log debug =>
                        "UNCOMPRESS LEFT:".length($abc//'').", buffer: ".length($dbuf).
                        ", length output:".length($self->{current_data_body});
                };
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
    my $size_todo;
    if(defined $size){
        $size_todo = $size - $self->{size_gotten};
    } else {
        $size_todo = length($hdl->{rbuf});
    }
    AE::log debug => "BODY_READER>>$size_todo got allready $self->{size_gotten}";
    my $next_block = substr($hdl->{rbuf}, 0, $size_todo, '');
    $self->{size_gotten} += length($next_block);
    if(exists $self->{uncompress}){
        &{$self->{uncompress}}(\$self->{current_data_body}, \$next_block);
    } else {
        $self->{current_data_body} .= $next_block;
    }
    if(!defined $size){
        return 0
    } elsif ($self->{size_gotten} >= $size){
        $self->consume_next();
        $self->get_next();
        return length($hdl->rbuf);
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
            $self->consume_next();
            $self->get_next();
        }
        return length($hdl->rbuf);
    }
    return 0;
}
