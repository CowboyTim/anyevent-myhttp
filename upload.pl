
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
        timeout     => 10,
        port        => 80
    },
    "username=s",
    "password=s",
    "httpsverify!",
    "timeout=i",
    "port=i",
    "server=s",
);

my $ua = {
    headers    => {
        "host"            => "localhost",
        "user-agent"      => "SomeClientSpeedTest/1.0",
        (($opts->{username} and $opts->{password})?
            ("Authorization" => "Basic ".encode_base64("$opts->{username}:$opts->{password}", '')):()),
        "content-length"  => 0,
        "connection"      => 'Keep-Alive',
        #'Accept-Encoding' => 'identity',
        #'Content-Encoding'=> 'gzip',
    },
    tls_ctx    => {
        method => 'SSLv3',
        verify => $opts->{httpsverify} // 0,
    },
    handle_params => {
        max_read_size => 100_000,
    },
    persistent => 1,
    keepalive  => 1,
    timeout    => $opts->{timeout}     // 300,
};

AnyEvent::Log::ctx->level("info");
$AnyEvent::Log::FILTER->level("trace");


my @data_set = (
    ['GET', 'http://www.google.be/', undef, {}],
    #['PUT', '/abc', (scalar(do {local $/; my $fh; open($fh, '<', $ARGV[0]) and <$fh>} x 1), {}]) x 100,
    #['PUT', '/def', encode_json([{abctest => 1}]), {}],
);

my $data_sent = 0;
my $orig_set_size = scalar(@data_set);
my @handles;
#while(@data_set){
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
                AE::log info => "OK:$data_sent, $orig_set_size, responsebody:$response";
                print $response;
                #push @data_set, ['GET', 'http://www.google.be/', undef, {}];
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
            cv => $cv
        });
        push @handles, $hdl;
    }
    AE::log info => "WAIT:".scalar(@handles);
    $$cv->recv();
    @handles = grep {!$_->{hdl}->destroyed()} @handles;
    AE::log info => "LOOP:".scalar(@handles);

#}
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
    $state->{-engine}{next_cb} = \&send_request;
    $state->{-engine}{request_cb} = \&read_request_status;
    schedule_next($state);
    my $hdl = new AnyEvent::Handle(
        connect => [$state->{-engine}{request_host}, $state->{-engine}{request_port}],
        on_connect => sub {
            my ($hdl, $host, $port, undef) = @_;
            AE::log info => "CONNECT:$hdl->{peername},$host:$port";
        }
    );
    $state->{hdl} = $hdl;
    $hdl->on_read(sub {
        my ($hdl) = @_;
        &{$state->{-engine}{request_cb}}($state);
    });
    my $disconnect = sub {
        my ($hdl, $fatal, $msg) = @_;
        $hdl->destroy();
        $state->{cv}->send();
    };

    $hdl->on_error(sub {
        my ($hdl, $fatal, $msg) = @_;
        AE::log error => $msg;
        &$disconnect(@_);
    });
    $hdl->on_eof($disconnect);
    $hdl->on_drain(sub {
        my ($hdl) = @_;
        &{$state->{-engine}{next_cb}}($state);
    });

    return bless $state, ref($class)||$class;
}

sub send_data {
    my ($state) = @_;
    my $str = substr($state->{-engine}{request_data}, 0, 10_000_000, '');
    unless (length($str)){
        $state->{-engine}{next_cb} = \&schedule_next;
        $state->{hdl}->on_drain(undef);
        return 0;
    }
    return 1;
}

sub get_next {
    my ($state) = @_;
    my $data = &{$state->{producer}}();
    unless(defined $data){
        return;
    }
    my $uri = URI->new($data->[1]);
    AE::log info => "$data->[0] ".$uri->as_string();
    #$uri->query_form(map {$_, $params->{$_}} grep {defined $params->{$_}} keys %{$params});
    return $data->[0], $data->[2], $uri->host(), $uri->port(), $uri->as_string(), $data->[3];
}

sub schedule_next {
    my ($state) = @_;
    my ($method, $body, $host, $port, $path, $headers) = get_next($state);
    unless($method){
        ${$state->{cv}}->send();
        return 0;
    }

    my $state_data = $state->{-engine};

    $state_data->{request_method}  = $method;
    $state_data->{request_data}    = $body // '';
    $state_data->{request_headers} = $headers;
    $state_data->{request_host}    = $host;
    $state_data->{request_port}    = $port;
    $state_data->{request_path}    = $path;
    $state_data->{next_cb} = \&send_request;

    return 1;
}

sub send_request {
    my ($state) = @_;
    my $state_data = $state->{-engine};
    $state_data->{next_cb} = \&send_data;

    my %hdr = (%{$ua->{headers}}, %{$state_data->{request_headers}//{}});
    $hdr{'content-length'} = length($state_data->{request_data});
    my $buf = "$state_data->{request_method} $state_data->{request_path} HTTP/1.1\r\n"
         . join('', map "\u$_: $hdr{$_}\r\n", grep defined $hdr{$_}, keys %hdr)
         . "\r\n";
    #print "HEADERS>>$buf<<\n";
    $state->{hdl}->push_write($buf);
    return 0;
}

sub read_request_status {
    my ($state) = @_;
    if ($state->{hdl}->rbuf =~ s/^HTTP\/1\.1 (\d+) (.*?)\r\n//){
        my ($code, $msg) = ($1, $2);
        AE::log info => "RESPONSE OK:$code, $msg";
        $state->{-engine}{request_cb} = \&read_response_headers;
        return 1;
    }
    return 0;
}

sub read_response_headers {
    my ($state) = @_;
    my $hdl = $state->{hdl};
    #print '>>'.$hdl->rbuf.'<<'."\n";
    if ($hdl->rbuf =~ s/^(.*?)\r\n//){
        my $line = $1;
        #print $hdl->rbuf, ",,,,,L:".length($line),":",$line,"\n\n";
        my $state_data = $state->{-engine};
        if(length($line) == 0){
            AE::log info => Dumper($state_data->{response_headers});
            my $chunked = ($state_data->{response_headers}{"Transfer-Encoding"}//'') =~ /\bchunked\b/i;
            my $len = $chunked ? undef : $state_data->{response_headers}{"Content-Length"};
            if(defined $len){
                $state_data->{size_wanted} = $len;
                $state_data->{request_cb}  = \&body_reader;
            } else {
                if($chunked){
                    $state_data->{request_cb} = \&chunked_body_reader;
                } else {
                    $state_data->{request_cb} = \&body_reader;
                }
            }
        } else {
            if(my ($h, $v) = ($line =~ m/^(.*?): (.*)/)){
                $state_data->{response_headers}{$h} = $v;
                return length($hdl->rbuf);
            }
            return 0;
        }
        return length($hdl->rbuf);
    }
    return 0;
}

sub body_reader {
    my ($state) = @_;
    my $hdl = $state->{hdl};
    #print '>>'.$hdl->rbuf.'<<'."\n";
    my $state_data = $state->{-engine};
    $state_data->{current_data_body} .= delete $hdl->{rbuf};
    if(defined $state_data->{size_wanted} and length($state_data->{current_data_body}) >= $state_data->{size_wanted}){
        $hdl->{rbuf} = substr(
            $state_data->{current_data_body},
            $state_data->{size_wanted},
            length($state_data->{current_data_body}),
            ''
        );
        &{$state->{consumer}}($state_data->{current_data_body});
        $state->{-engine}{next_cb} = \&schedule_next;
        return length($hdl->rbuf);
    }
    return 0;
}

sub chunk_reader {
    my ($state) = @_;
    my $hdl = $state->{hdl};
    my $state_data = $state->{-engine};
    AE::log debug => "CHUNK>>$state_data->{chunk_wanted_size}>>".$hdl->rbuf;
    my $size_todo = $state_data->{chunk_wanted_size} - length($state_data->{current_chunk}//'');
    $state_data->{current_chunk} .= substr($hdl->{rbuf}, 0, $size_todo, '');
    if(length($state_data->{current_chunk}) >= $state_data->{chunk_wanted_size}){
        $state_data->{current_data_body} .= delete $state_data->{current_chunk};
        $state_data->{request_cb} = \&chunked_body_reader;
        return length($hdl->rbuf);
    }
    AE::log debug => "LEFTCHUNK>>".$hdl->rbuf;
    return 0;
}

sub chunked_body_reader {
    my ($state) = @_;
    my $hdl = $state->{hdl};
    AE::log debug => "CHUNKBODYREADER>>".$hdl->rbuf;
    if($hdl->rbuf =~ s/^\r\n//){
        return length($hdl->rbuf);
    }
    if($hdl->rbuf =~ s/^([0-9A-Fa-f]+?)\r\n//){
        my $size = hex($1);
        AE::log debug => "chunk size: hex($1) = $size";
        my $state_data = $state->{-engine};
        if($size){
            $state_data->{chunk_wanted_size} = $size;
            $state_data->{request_cb} = \&chunk_reader;
        } else {
            &{$state->{consumer}}($state_data->{current_data_body});
            $state->{-engine}{next_cb} = \&schedule_next;
        }
        return length($hdl->rbuf);
    }
    return 0;
}

