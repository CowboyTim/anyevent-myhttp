
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
    #['GET', 'https://www.google.com/', undef, {Connection => 'close'}],
    ['GET', 'https://www.google.be/', undef, {}],
    ['GET', 'https://www.google.be/', undef, {Connection => 'close'}],
    #['GET', 'https://www.google.be/', undef, {}],
    #['HEAD', 'https://www.google.com/', undef, {'TE' => 'chunked'}],
    #['HEAD', 'https://www.google.be/', undef, {'TE' => 'chunked'}],
    #['GET', 'https://www.google.be/', undef, {'Accept-Encoding' => 'gzip', 'TE' => 'chunked'}],
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
    while(scalar(@handles) < 1 and @data_set){
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
                    #${$cv}->send();
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

    $self->{response_reader} = \&read_response_status;

    # make the handle
    my $uri = $self->{current_request}{uri};
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
        $self->_slurp();
    });
    $hdl->on_error(sub {
        my ($hdl, $fatal, $msg) = @_;
        AE::log error => "on_error: $msg";
        $self->_disconnect($fatal, $msg);
    });
    $hdl->on_eof(sub {
        my ($hdl, $fatal, $msg) = @_;
        AE::log error => "on_eof: $msg";
        $self->_disconnect($fatal, $msg);
    });
    $hdl->on_drain(sub {
        my ($hdl) = @_;
        AE::log debug => "on_drain(): called request_sender";
        &{$self->{request_sender}}($self);
    });

    return $self;
}

sub _disconnect {
    my ($self, $fatal, $msg) = @_;
    my $hdl = $self->{hdl};
    AE::log info => "DISCONNECT: left:".length($hdl->rbuf);

    # 'close' Connections that have no Content-Length set will just
    # disconnect instead of letting the condition be true in
    # body_reader(), hence we do a consume_next(). *Sigh* HTTP
    # sucks.
    if(($self->{response_headers}{Connection} // '') eq 'close'){
        $self->consume_next();
    }
    $self->_slurp();
    AE::log info => "DISCONNECT (bis): left:".length($hdl->rbuf);
    $hdl->destroy();
    ${$self->{cv}}->send();
}

sub _slurp {
    my ($self) = @_;
    my $hdl = $self->{hdl};
    AE::log debug => "on_read() called";
    while(length($hdl->rbuf)){
        my $orig = length($hdl->rbuf);
        &{$self->{response_reader}}($self);
        last if $orig == length($hdl->rbuf);
    }
}

sub consume_next {
    my ($self) = @_;
    $self->{response_reader} = \&read_response_status;
    my ($code, $msg, $body, $headers) = @{$self}{qw(
        response_status_code
        response_status_message
        data_body
        response_headers
    )};
    if(defined $code and $code eq '302'){
        AE::log info => "REDIRECT: $code [$self->{request_method}, $headers->{Location}, undef, '<HEADERS>']";
        # redirect: make a new request at the start of the queue
        unshift @{$self->{requests}}, [$self->{request_method}, $headers->{Location}, undef, $self->{request_headers}];
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

    shift @{$self->{request_queue}};

    # schedule next, make on_drain() produce data again!
    $self->schedule_next();
    $self->{hdl}->on_drain(sub {
        my ($hdl) = @_;
        AE::log debug => "on_drain(): called request_sender";
        &{$self->{request_sender}}($self);
    });
}

sub send_data {
    my ($self) = @_;
    my $str = substr($self->{current_request}{data}, 0, 10_000_000, '');
    unless (length($str)){
        $self->{request_sender} = sub {$self->schedule_next()};
        $self->{hdl}->on_drain(undef);
        return 0;
    }
    $self->{hdl}->push_write($str);
    return 1;
}

sub schedule_next {
    my ($self) = @_;
    my $data = &{$self->{producer}}();
    unless(defined $data){
        $self->{hdl}->on_drain(undef);
        return 0;
    }

    my $uri = URI->new($data->[1]);
    AE::log info => "$data->[0] ".$uri->as_string();
    #$uri->query_form(map {$_, $params->{$_}} grep {defined $params->{$_}} keys %{$params});

    # start new
    $self->{request_sender} = \&send_request;
    push @{$self->{request_queue} //= []}, my $r = $self->{current_request} = {
        method  => $data->[0],
        data    => $data->[2] // '',
        headers => $data->[3],
        uri     => $uri,
    };

    # add some headers
    $r->{headers}{'Content-Length'} = length($r->{data});
    $r->{headers}{'Host'}  = $uri->host();
    $r->{headers}{'Host'} .= ':'.$uri->port() if ($uri->port()//'') ne '80';

    AE::log debug => "schedule_next: ".$uri->as_string();
    return 1;
}

sub send_request {
    my ($self) = @_;
    $self->{request_sender} = \&send_data;

    my %hdr = (%{$self->{headers}}, %{$self->{current_request}{headers}//{}});
    my $buf = join("\r\n",
        "$self->{current_request}{method} ".$self->{current_request}{uri}->as_string()." HTTP/1.1",
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
        $self->{response_reader} = \&read_response_headers;
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

            # if it was just a HEAD request, exit and take the next one.
            if ($self->{request_queue}[0]{method} ~~ ['HEAD', 'DELETE', 'TRACE', 'OPTIONS']){
                $self->consume_next();
                $self->get_next();
                return length($hdl->rbuf);
            }

            # if chunked, use the chunked body reader, else just the
            # regular one
            my $chunked = ($rh->{"Transfer-Encoding"}//'') =~ /\bchunked\b/i;
            if(!$chunked){
                $self->{data_body}   = '';
                $self->{size_gotten} = 0;
                $self->{size_wanted} = $rh->{'Content-Length'};
                $self->{response_reader}  = \&body_reader;
            } else {
                $self->{response_reader}  = \&chunked_body_reader;
            }

            $self->{handle_body} = \&{'handle_body_'.(
                 $rh->{'Content-Encoding'} ~~ ['gzip'] # to be extended
                ?$rh->{'Content-Encoding'}:''
            )};
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

sub handle_body_ {
    my ($self, $buf, $input) = @_;
    $$buf .= $$input;
}

sub handle_body_gzip {
    my ($self, $buf, $input, $dbuf) = @_;
    $$dbuf .= $$input;
    AE::log debug => Dumper($input);
    gunzip($dbuf => $buf, TrailingData => \my $abc);
    AE::log debug =>
        "UNCOMPRESS LEFT:".length($abc//'').", buffer: ".length($$dbuf).
        ", length output:".length($$buf);
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
    &{$self->{handle_body}}($self, \$self->{data_body}, \$next_block, \$self->{_scratch});
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
        &{$self->{handle_body}}($self, \$self->{data_body}, \delete $self->{current_chunk}, \$self->{_scratch});
        $self->{response_reader} = \&chunked_body_reader;
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
            $self->{response_reader} = \&chunk_reader;
        } else {
            $self->consume_next();
            $self->get_next();
        }
        return length($hdl->rbuf);
    }
    return 0;
}
