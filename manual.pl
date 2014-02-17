#!/usr/bin/perl
#
# PlugBuild Builder Manual Upload Client (primary architecture)
#

use strict;
use FindBin qw($Bin);
use Config::General qw(ParseConfig);
use Switch;
use AnyEvent;
use AnyEvent::TLS;
use AnyEvent::Handle;
use AnyEvent::Socket;
use JSON::XS;

my %config = ParseConfig("$Bin/client.conf");

# other variables, probably shouldn't touch these
my $state;
my %files;
my $current_filename;
my $current_fh;

# check arguments, set upload file list
if (($#ARGV + 1) < 3) {
    print "usage: ./manual.pl <repo> <package> <file1.tar.xz ...>\n";
    exit 1;
}

$state->{repo}    = $ARGV[0];
$state->{pkgbase} = $ARGV[1];
$state->{arch}    = $config{primary};

# get package files from arguments
foreach my $n (2 .. $#ARGV) {
    my $filename = $ARGV[$n];
    
    # send file to farmer
    if (defined $config{farmer}) {
        `rsync -rtl $filename $config{farmer}/$state->{arch}`;
    }
    
    # send file to plugbuild
    do {
        print " -> Uploading to plugbuild..\n";
        `rsync -rtl $filename $config{build_pkg}/$state->{arch}`;
    } while ($? >> 8);

    next if ($filename =~ /.*\.sig$/);
    my $md5sum_file = `md5sum $filename`;
    $md5sum_file = (split(/ /, $md5sum_file))[0];
    $files{$filename} = $md5sum_file;
    $current_filename = $filename;
}

# AnyEvent setup
my $condvar = AnyEvent->condvar;
my $h;
my $w = AnyEvent->signal(signal => "INT", cb => sub { $condvar->broadcast; });
my $timer_retry;

# main event loop
con();
$condvar->wait;

# shutdown
$h->destroy;


### control subroutines

# connect to service
sub con {
    $h = new AnyEvent::Handle
        connect             => [$config{server} => $config{port}],
        tls                 => "connect",
        tls_ctx             => {
                                verify          => 1,
                                ca_file         => "$Bin/$config{ca_file}",
                                cert_file       => "$Bin/$config{cert_file_manual}",
                                cert_password   => $config{password},
                                verify_cb       => sub { cb_verify_cb(@_); }
                                },
        keepalive           => 1,
        no_delay            => 1,
        rtimeout            => 3, # 3 seconds to authenticate with SSL before destruction
        on_rtimeout         => sub { $h->destroy; $condvar->broadcast; },
        on_error            => sub { cb_error(@_); },
        on_starttls         => sub { cb_starttls(@_); },
        on_connect_error    => sub { cb_error($_[0], 0, $_[1]); }
        ;
}

# callback that handles peer certificate verification
sub cb_verify_cb {
    my ($tls, $ref, $cn, $depth, $preverify_ok, $x509_store_ctx, $cert) = @_;
    
	# depth is zero when we're verifying peer certificate
    return $preverify_ok if $depth;
    
    # get certificate information
    my $orgunit = Net::SSLeay::X509_NAME_get_text_by_NID(Net::SSLeay::X509_get_subject_name($cert), Net::SSLeay->NID_organizationalUnitName);
    my $common = Net::SSLeay::X509_NAME_get_text_by_NID(Net::SSLeay::X509_get_subject_name($cert), Net::SSLeay->NID_commonName);
    my @cert_alt = Net::SSLeay::X509_get_subjectAltNames($cert);
    my $ip = AnyEvent::Socket::parse_address $cn;
    
    # verify ip address in client cert subject alt name against connecting ip
    while (my ($type, $name) = splice @cert_alt, 0, 2) {
        if ($type == Net::SSLeay::GEN_IPADD()) {
            if ($ip eq $name) {
                print "verified ". Net::SSLeay::X509_NAME_oneline(Net::SSLeay::X509_get_subject_name($cert)) ."\n";
                return 1;
            }
        }
    }
    
    print "failed verification for $ref->{peername}: ". Net::SSLeay::X509_NAME_oneline(Net::SSLeay::X509_get_subject_name($cert)) ."\n";
    return 0;
}

# callback on socket error
sub cb_error {
    my ($handle, $fatal, $message) = @_;
    
    if ($fatal) {
        print "fatal ";
    }
    print "error from $handle->{peername} - $message\n";
    $condvar->broadcast;
}

# callback on whether ssl auth succeeded
sub cb_starttls {
    my ($handle, $success, $error) = @_;
    
    if ($success) {
        $handle->rtimeout(0);   # stop auto-destruct
        $handle->on_read(sub { $handle->push_read(json => sub { cb_read(@_); }) });    # set read callback
        $handle->push_write(json => { command => 'sync', state => 'manual' });
        $state->{command} = 'prep';
        $h->push_write(json => $state);
        return;
    }
    
    # kill the client, bad ssl auth
    $condvar->broadcast;
}

# callback for reading data
sub cb_read {
    my ($handle, $data) = @_;
    
    return if (!defined $data);
    
    switch ($data->{command}) {
        case "add" {
            if ($data->{response} eq "OK") {
                delete $files{$current_filename};
                undef $current_filename;
            } elsif ($data->{response} eq "FAIL") {
                print " -> failed to add file, trying again..\n";
            }
            cb_add();
        }
        case ["done", "fail"] {
            $condvar->broadcast;
        }
        case "prep" {
            cb_add();
        }
    }
}

sub cb_add {
    # set current file if needed
    if (!$current_filename && (my ($filename, $md5sum) = each(%files))) {
        $current_filename = $filename;
    }
    
    # add package file
    if ($current_filename) {
        my $filename = $current_filename;
        $filename =~ s/^\/.*\///;
        my $md5sum = $files{$current_filename};
        # query file for extra information
        my $info = `tar -xOf $current_filename .PKGINFO 2>&1`;
        my ($pkgname) = $info =~ m/pkgname = (.*)\n?/;
        my ($pkgver) = $info =~ m/pkgver = (.*)\n?/;
        my $pkgrel;
        ($pkgver, $pkgrel) = split(/-/, $pkgver, 2);
        my ($pkgdesc) = $info =~ m/pkgdesc = (.*)\n?/;
        
        # construct message for server
        my %reply = ( command   => "add",
                      arch      => $state->{arch},
                      pkgbase   => $state->{pkgbase},
                      pkgname   => $pkgname,
                      pkgver    => $pkgver,
                      pkgrel    => $pkgrel,
                      pkgdesc   => $pkgdesc,
                      repo      => $state->{repo},
                      filename  => $filename,
                      md5sum    => $md5sum );
                
        # communicate reply
        $h->push_write(json => \%reply);
        return;
        
    # otherwise, send done
    } else {
        print " -> finished adding, sending done\n";
        $state->{command} = 'done';
        $h->push_write(json => $state);
    }
}

