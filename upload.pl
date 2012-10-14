
use strict; use warnings;

use Data::Dumper;
use Getopt::Long;
use AnyEvent;
use AnyEvent::HTTP;
use EV;
use MIME::Base64 qw(encode_base64);
use URI;
use Errno;
use AnyEvent::Socket;
use AnyEvent::Handle;
use AnyEvent::Log;
use IO::Socket::SSL;
use IO::Socket::INET;
use JSON;
use Compress::Zlib;
use Compress::Bzip2;
#$AnyEvent::Log::FILTER->level("trace");

use Benchmark;


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


sub send_data {
    my ($state, $hdl) = @_;
    my $str = substr($state->{-engine}{current_data}, 0, 10_000_000, '');
    unless (length($str)){
        $state->{-engine}{next_cb} = \&send_request;
        $hdl->on_drain(undef);
        return '';
    }
    return $str;
}

sub send_request {
    my ($state, $hdl) = @_;
    my $data = &{$state->{producer}}($hdl);
    unless(defined $data){
        $hdl->on_drain(undef);
        return '';
    }

    my $uriref = $data->[1];
    #my $params = {};
    #my $cstr = "$opts->{proto}://$opts->{server}:$opts->{port}/$uriref";
    #my $uri = URI->new($cstr);
    #$uri->query_form(map {$_, $params->{$_}} grep {defined $params->{$_}} keys %{$params});

    my $state_data = $state->{-engine};

    my %hdr = (%{$ua->{headers}}, %{$data->[3]//{}});
    $state_data->{orig_sent_data} = $data;
    #$data = Compress::Zlib::memGzip($data);
    $state_data->{current_data} = $data->[2] // '';
    $state_data->{next_cb} = \&send_data;
    $hdr{'content-length'} = length($state_data->{current_data});
    my $buf = "$data->[0] $uriref HTTP/1.1\r\n"
         . join('', map "\u$_: $hdr{$_}\r\n", grep defined $hdr{$_}, keys %hdr)
         . "\r\n";
    #print "HEADERS>>$buf<<\n";
    return $buf;
}

sub read_request_status {
    my ($state, $hdl) = @_;
    if ($hdl->rbuf =~ s/^HTTP\/1\.1 (\d+) (.*?)\r\n//){
        my ($code, $msg) = ($1, $2);
        AE::log info => "RESPONSE OK:$code, $msg";
        $state->{-engine}{request_cb} = \&read_response_headers;
        return 1;
    }
    return 0;
}

sub read_response_headers {
    my ($state, $hdl) = @_;
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
    my ($state, $hdl) = @_;
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
        &{$state->{consumer}}($hdl, $state_data->{current_data_body});
        init_state($hdl, $state);
        return length($hdl->rbuf);
    }
    return 0;
}

sub chunk_reader {
    my ($state, $hdl) = @_;
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
    my ($state, $hdl) = @_;
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
            &{$state->{consumer}}($hdl, $state_data->{current_data_body});
            init_state($hdl, $state);
        }
        return length($hdl->rbuf);
    }
    return 0;
}

sub init_state {
    my ($hdl, $state) = @_;
    $state->{-engine} = { 
        next_cb    => \&send_request,
        request_cb => \&read_request_status,
    };
    $hdl->on_read(sub {
        my ($hdl) = @_;
        while($state->{-engine}{request_cb}($state, $hdl)){
            # might consume cpu cycles while exit is wanted and such
            #print STDERR "NOK\n";
        }
    });
    $hdl->on_drain(sub {
        my ($hdl) = @_;
        my $str = $state->{-engine}{next_cb}($state, $hdl);
        #print "WRITER>>".$str."<<\n";
        $hdl->push_write($str) if length($str);
    });

    my $disconnect = sub {
        my ($hdl, $fatal, $msg) = @_;
        &{$state->{error_handler}}($state->{-engine}{orig_sent_data});
        $hdl->destroy();
        $state->{cv}->send();
    };

    $hdl->on_error(sub {
        my ($hdl, $fatal, $msg) = @_;
        AE::log error => $msg;
        &$disconnect(@_);
    });
    $hdl->on_eof($disconnect);
    return $state;
}

sub new_handle {
    my (%args) = @_;

##    my $dest = "$opts->{server}:$opts->{port}";
##    my $sock = IO::Socket::INET->new(
##        PeerAddr        => $dest,
##        Proto           => 'tcp'
##    ) or die "connect error $dest: $@\n";
##    $sock->blocking(0);
    #$sock->setsockopt(SOL_SOCKET, SO_SNDBUF, $self->{sndbuf}) if $self->{sndbuf};
    my $hdl = new AnyEvent::Handle(
        connect => [$opts->{server}, $opts->{port}],
        on_connect => sub {
            my ($hdl, $host, $port, undef) = @_;
            AE::log info => "CONNECT:$hdl->{peername},$host:$port";
        }
    );
    init_state($hdl, \%args);
    return $hdl;
}

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
        my $hdl = new_handle(
            # producer
            producer => sub {
                my ($hdl) = @_;
                AE::log info => "SEND:".scalar(@data_set).','.$hdl->{peername};
                shift @data_set
            },
            # consumer
            consumer => sub {
                my ($hdl, $response) = @_;
                AE::log info => "RESPONSE:".scalar(@data_set).','.$hdl->{peername};
                $data_sent++;
                AE::log info => "OK:$data_sent, $orig_set_size, responsebody:$response";
                print $response;
                #push @data_set, ['GET', 'http://www.google.be/', undef, {}];
                if(scalar(@data_set) == 0 and $data_sent == $orig_set_size){
                    AE::log info => "END OK:$data_sent, $orig_set_size, ".scalar(@data_set);
                    ${$cv}->send();
                }
            },
            consumer_iterator => sub {
                my ($hdl, $chunk, $finalized) = @_;
            },
            # error: put back in queue
            error_handler => sub {
                unshift @data_set, $_[0];
            },
            # condvar
            cv => $cv
        );
        push @handles, $hdl;
    }
    AE::log info => "WAIT:".scalar(@handles);
    $$cv->recv();
    @handles = grep {!$_->destroyed()} @handles;
    AE::log info => "LOOP:".scalar(@handles);

#}
AE::log info => "LOOP END:".scalar(@handles);
