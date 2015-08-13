#!/usr/bin/perl
# Copyright (c) 2015  Timm Murray
# All rights reserved.
# 
# Redistribution and use in source and binary forms, with or without 
# modification, are permitted provided that the following conditions are met:
# 
#     * Redistributions of source code must retain the above copyright notice, 
#       this list of conditions and the following disclaimer.
#     * Redistributions in binary form must reproduce the above copyright 
#       notice, this list of conditions and the following disclaimer in the 
#       documentation and/or other materials provided with the distribution.
# 
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" 
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE 
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE 
# ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE 
# LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR 
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF 
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS 
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN 
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) 
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE 
# POSSIBILITY OF SUCH DAMAGE.
use v5.14;
use warnings;
use Getopt::Long ();
use Time::HiRes ();
use HiPi::Wiring qw( :wiring );
use Sereal::Decoder qw{};
use Fcntl qw( :flock );
use AnyEvent;
use AnyEvent::HTTP::LWP::UserAgent;
use File::Temp 'tempfile';
use Device::PCD8544;
use Device::WebIO::RaspberryPi;
use Imager;

use constant DEBUG => 1;

use constant DO_USE_LCD           => 0;
use constant IMG_WIDTH            => 800;
use constant IMG_HEIGHT           => 600;
use constant IMG_QUALITY          => 100;
use constant IMG_IMAGER_QUALITY   => 70;
use constant FLIP_IMAGE           => 1; # Set if your camera is upside-down
use constant DEFAULT_PIC          => 'bodgery_default.jpg';
use constant PRIVATE_KEY_FILE     => 'upload_key.rsa';
use constant SERVER_USERNAME      => '';
use constant SERVER_HOST          => ''; # Fill in hostname or IP
use constant SERVER_UPLOAD_PATH   => ''; # Fill in upload path on server
use constant DOOR_OPEN_SEC        => 10;


my $SSL_CERT         = 'app.tyrion.crt';
my $DOMAIN           = 'app.tyrion.thebodgery.org';
my $AUTH_REALM       = 'Required';
my $USERNAME         = '';
my $PASSWORD         = '';
my $PIEZO_PIN        = 18;
my $LOCK_PIN         = 22;
my $UNLOCK_PIN       = 25;
my $OPEN_SWITCH      = 17;
# Zelda Uncovered Secret Music
# Notes: G2 F2# D2# A2 G# E2 G2# C3 
my $GOOD_NOTES       = [qw{ 1568 1480 1245 880 831 1319 1661 2093 }];
my $BAD_NOTES        = [ 60 ];
my $NOTE_DURATION      = 0.2;
my $UNLOCK_DURATION_MS = 10_000;
my $SEREAL_FALLBACK_DB = '/var/tmp-ramdisk/rfid_fallback.db';
my $TMP_DIR            = '/var/tmp-ramdisk';
my $LED_PIN       = 4;
my $LCD_POWER_PIN = 3;
my $LCD_RST_PIN   = 24;
my $LCD_DC_PIN    = 23;
my $TAKE_PICTURE_INTERVAL = 5;
Getopt::Long::GetOptions(
    'ssl-cert=s'    => \$SSL_CERT,
    'host=s'        => \$DOMAIN,
    'username=s'    => \$USERNAME,
    'password=s'    => \$PASSWORD,
    'fallback-db=s' => \$SEREAL_FALLBACK_DB,
    'tmp-dir=s'     => \$TMP_DIR,
);

my $HOST = 'https://' . $DOMAIN;

my @PIC_CLOSED = (
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0F, 0x73, 0xC6, 0x0C, 0x30, 0xE0, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xC0, 0xF0, 0xE0, 0xF8, 0x0C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80, 0xC0, 0xC3, 0xEE, 0x7C, 0x7F, 0x3E, 0x38, 0x1C, 0x0C, 0x0E, 0x06, 0x07, 0x07, 0x0E, 0x0E, 0x1C, 0x18, 0x3E, 0x3C, 0x7F, 0xFF, 0xCF, 0xCF, 0x81, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80, 0xE0, 0x20, 0x20, 0x20, 0x20, 0xC0, 0xC0, 0xC0, 0xC0, 0xFF, 0xFF, 0x01, 0x00, 0x00, 0x00, 0x01, 0x03, 0x03, 0xFE, 0xFE, 0xFE, 0xFE, 0x86, 0x86, 0xC6, 0xFE, 0xFE, 0x7E, 0x3C, 0x18, 0x00, 0x00, 0x00, 0x01, 0xFF, 0xFF, 0xFF, 0xC0, 0xC0, 0xE0, 0xF0, 0xF0, 0x30, 0x30, 0x30, 0x20, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x06, 0x08, 0x08, 0x08, 0x0C, 0x06, 0x03, 0x03, 0x03, 0xFF, 0xFF, 0x80, 0x80, 0x00, 0x00, 0x00, 0x00, 0x40, 0x7F, 0x7F, 0x7F, 0x7F, 0x41, 0x41, 0x61, 0x61, 0x7F, 0x7F, 0x3F, 0x3E, 0x08, 0x00, 0x00, 0x80, 0xFF, 0xFF, 0xFF, 0x03, 0x07, 0x07, 0x0F, 0x1F, 0x18, 0x18, 0x08, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0xC1, 0xF3, 0xF3, 0xFE, 0xFE, 0x3C, 0x7C, 0x18, 0x38, 0x30, 0x60, 0xE0, 0x60, 0x70, 0x30, 0x38, 0x18, 0x0C, 0x1E, 0x3E, 0xF7, 0xC3, 0x03, 0x01, 0x00, 0x00, 0x00, 0xE0, 0x10, 0x08, 0x08, 0x08, 0x08, 0x00, 0x00, 0x08, 0x08, 0xF8, 0x00, 0x00, 0x00, 0xC0, 0x60, 0x20, 0x20, 0x60, 0xC0, 0x00, 0x00, 0xC0, 0xA0, 0xA0, 0x20, 0x20, 0x00, 0x00, 0xC0, 0xA0, 0xA0, 0xA0, 0xC0, 0x00, 0x00, 0xC0, 0x60, 0x20, 0x20, 0xF8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x40, 0x3C, 0x0F, 0x0F, 0x0F, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x07, 0x1C, 0x30, 0x00, 0x00, 0x01, 0x02, 0x04, 0x04, 0x04, 0x04, 0x00, 0x00, 0x00, 0x00, 0x07, 0x00, 0x00, 0x00, 0x03, 0x06, 0x04, 0x04, 0x06, 0x03, 0x00, 0x00, 0x06, 0x04, 0x04, 0x05, 0x03, 0x00, 0x00, 0x03, 0x04, 0x04, 0x04, 0x04, 0x00, 0x00, 0x03, 0x04, 0x04, 0x02, 0x07, 0x00, 0x00, 0x00, 0x00,
);
my @PIC_OPEN = (
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0F, 0x73, 0xC6, 0x0C, 0x30, 0xE0, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xC0, 0xF0, 0xE0, 0xF8, 0x0C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80, 0x60, 0x20, 0x20, 0x60, 0x80, 0x00, 0x00, 0x80, 0x00, 0x80, 0x80, 0x00, 0x00, 0x00, 0x00, 0x80, 0x80, 0x80, 0x00, 0x00, 0x00, 0x80, 0x00, 0x80, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80, 0xC0, 0xC3, 0xEE, 0x7C, 0x7F, 0x3E, 0x38, 0x1C, 0x0C, 0x0E, 0x06, 0x07, 0x07, 0x0E, 0x0E, 0x1C, 0x18, 0x3E, 0x3C, 0x7F, 0xFF, 0xCF, 0xCF, 0x81, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x07, 0x18, 0x10, 0x10, 0x18, 0x07, 0x00, 0x00, 0x7F, 0x11, 0x10, 0x18, 0x0F, 0x00, 0x00, 0x0F, 0x12, 0x12, 0x12, 0x13, 0x00, 0x00, 0x1F, 0x01, 0x00, 0x00, 0x1F, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80, 0xE0, 0x20, 0x20, 0x20, 0x20, 0xC0, 0xC0, 0xC0, 0xC0, 0xFF, 0xFF, 0x01, 0x00, 0x00, 0x00, 0x01, 0x03, 0x03, 0xFE, 0xFE, 0xFE, 0xFE, 0x86, 0x86, 0xC6, 0xFE, 0xFE, 0x7E, 0x3C, 0x18, 0x00, 0x00, 0x00, 0x01, 0xFF, 0xFF, 0xFF, 0xC0, 0xC0, 0xE0, 0xF0, 0xF0, 0x30, 0x30, 0x30, 0x20, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x06, 0x08, 0x08, 0x08, 0x0C, 0x06, 0x03, 0x03, 0x03, 0xFF, 0xFF, 0x80, 0x80, 0x00, 0x00, 0x00, 0x00, 0x40, 0x7F, 0x7F, 0x7F, 0x7F, 0x41, 0x41, 0x61, 0x61, 0x7F, 0x7F, 0x3F, 0x3E, 0x08, 0x00, 0x00, 0x80, 0xFF, 0xFF, 0xFF, 0x03, 0x07, 0x07, 0x0F, 0x1F, 0x18, 0x18, 0x08, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0xC1, 0xF3, 0xF3, 0xFE, 0xFE, 0x3C, 0x7C, 0x18, 0x38, 0x30, 0x60, 0xE0, 0x60, 0x70, 0x30, 0x38, 0x18, 0x0C, 0x1E, 0x3E, 0xF7, 0xC3, 0x03, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x40, 0x3C, 0x0F, 0x0F, 0x0F, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x07, 0x1C, 0x30, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
);


my $UA = AnyEvent::HTTP::LWP::UserAgent->new;
$UA->credentials( $DOMAIN . ':443', $AUTH_REALM, $USERNAME, $PASSWORD );
$UA->ssl_opts(
    SSL_ca_file => $SSL_CERT,
);


sub get_tag_input_event
{
    my ($dev) = @_;
    return sub {
        my $tag = get_next_tag();
        my $result = check_tag({
            dev              => $dev,
            tag              => $tag,
            on_success       => \&do_success_action,
            on_inactive_tag  => \&do_inactive_tag_action,
            on_tag_not_found => \&do_tag_not_found_action,
            on_unknown_error => \&do_unknown_error_action,
            fallback_check   => \&check_tag_sereal_fallback,
        });
    };
}

sub get_next_tag
{
    my $next_tag = <>;
    chomp $next_tag;
    return $next_tag;
}

sub check_tag
{
    my (%args) = %{ +shift };
    my ($tag, $dev, $on_success, $on_inactive_tag, $on_tag_not_found,
        $on_unknown_error, $fallback_check) = @args{qw[
            tag dev on_success on_inactive_tag on_tag_not_found on_unknown_error
            fallback_check ]};

    my $start_time = [Time::HiRes::gettimeofday];
    $UA->get_async( $HOST . '/check_tag/' . $tag )->cb(sub {
        my $end_time   = [Time::HiRes::gettimeofday];
        my $duration   = Time::HiRes::tv_interval( $start_time, $end_time );

        my $r    = shift->recv;
        my $code = $r->code;

        say "Response time: " . sprintf( '%.0f ms', $duration * 1000);

        if(! defined $code ) {
            $on_unknown_error->( $dev );
        }
        elsif( $code == 200 ) {
            $on_success->( $dev );
        }
        elsif( $code == 403 ) {
            $on_inactive_tag->( $dev );
        }
        elsif( $code == 404 ) {
            $on_tag_not_found->( $dev );
        }
        else {
            say "Unknown error from server, checking fallback DB";
            if( $fallback_check->( $tag ) ) {
                $on_success->( $dev );
            }
            else {
                $on_unknown_error->( $dev );
            }
        }
    });

    return 1;
}

sub check_tag_sereal_fallback
{
    my ($tag) = @_;
    if(! -e $SEREAL_FALLBACK_DB ) {
        say "Fallback DB ($SEREAL_FALLBACK_DB) does not exist";
        return 0;
    }

    open( my $fh, '<', $SEREAL_FALLBACK_DB ) or do {
        say "Could not open fallback DB ($SEREAL_FALLBACK_DB): $!";
        return 0;
    };
    flock( $fh, LOCK_SH ) or say "Could not get a shared lock on fallback DB"
        . ", because [$!], checking it anyway . . .";

    # TODO Slurp with AnyEvent
    local $/ = undef;
    my $in = <$fh>;
    close $fh;

    my $decoder = get_sereal_decoder();
    $decoder->decode( $in, my $data );

    if( exists $data->{$tag} ) {
        say "Found tag in fallback DB";
        return 1;
    }
    else {
        say "Did not find tag in fallback DB";
        return 0;
    }
}


sub play_notes
{
    my (@notes) = @_;

    foreach my $freq (@notes) {
        HiPi::Wiring::softToneWrite( $PIEZO_PIN, $freq );
        Time::HiRes::sleep( $NOTE_DURATION );
    }

    HiPi::Wiring::softToneWrite( $PIEZO_PIN, 0 );
    HiPi::Wiring::digitalWrite( $PIEZO_PIN, WPI_LOW );

    return 1;
}

sub do_success_action
{
    my ($dev) = @_;
    say "Good RFID";
    unlock_door( $dev );

    my $start_time = Time::HiRes::time();
    my $expect_end_time = $start_time + ($UNLOCK_DURATION_MS / 1000);

    my $now = $start_time;
    while( $now <= $expect_end_time ) {
        play_notes( @$GOOD_NOTES );
        $now = Time::HiRes::time();
    }

    lock_door( $dev );
    return 1;
}

sub do_inactive_tag_action
{
    say "Inactive RFID";
    play_notes( @$BAD_NOTES );
    return 1;
}

sub do_tag_not_found_action
{
    say "Did not find RFID";
    play_notes( @$BAD_NOTES );
    return 1;
}

sub do_unknown_error_action
{
    say "Unknown error";
    play_notes( @$BAD_NOTES );
    return 1;
}

sub send_pic
{
    my ($filename) = @_;
    say "Sending pic to main server";

    my @scp_command = (
        'scp',
        '-i', PRIVATE_KEY_FILE,
        $filename,
        SERVER_USERNAME . '@' . SERVER_HOST . ':' . SERVER_UPLOAD_PATH,
    );
    (system( @scp_command ) == 0)
        or warn "Could not exec '@scp_command': $!\n";

    return 1;
}

{
    my $sereal;
    sub get_sereal_decoder
    {
        return $sereal if defined $sereal;

        $sereal = Sereal::Decoder->new({
        });

        return $sereal;
    }
}

sub get_lcd
{
    my ($rpi) = @_;
    return undef unless DO_USE_LCD;
    say "Setting up LCD . . . " if DEBUG;
    my $lcd = Device::PCD8544->new({
        dev      => 0,
        speed    => Device::PCD8544->SPEED_4MHZ,
        webio    => $rpi,
        power    => $LCD_POWER_PIN,
        rst      => $LCD_RST_PIN,
        dc       => $LCD_DC_PIN,
        contrast => 0x3C,
        bias     => Device::PCD8544->BIAS_1_40,
    });
    $lcd->init;
    $lcd->set_image( \@PIC_CLOSED );
    $lcd->update;

    say "Done setting LCD" if DEBUG;
    return $lcd;
}

sub get_open_status_callbacks
{
    my ($rpi) = @_;

    my $is_open = 0;
    my $prev_is_open = 0;
    my $input_callback = sub {
        $is_open = $rpi->input_pin( $OPEN_SWITCH );

        if( $is_open && !$prev_is_open ) {
            unlock_door( $rpi );
	    my $input_timer; $input_timer = AnyEvent->timer(
		after    => DOOR_OPEN_SEC,
		cb       => sub { 
                    lock_door( $rpi );
                    $input_timer;
                },
	    );
        }

        $prev_is_open = $is_open;

        say "Open setting: $is_open" if DEBUG;
        return 1;
    };

    my $lcd = get_lcd( $rpi );
    my $lcd_callback = sub {
        return 0 unless DO_USE_LCD;
        my $pic = $is_open ? \@PIC_OPEN : \@PIC_CLOSED;
        say "Setting LCD pic (is open: $is_open)" if DEBUG;
        $lcd->set_image( $pic );
        $lcd->update;
        return 1;
    };

    my $picture_callback = sub {
        say "Checking if we should send an image . . . " if DEBUG;

        if( $is_open ) {
            say "Shop open, getting image";
            my $fh = $rpi->img_stream( 0, 'image/jpeg' );
            my ($tmp_fh, $tmp_filename) = tempfile( DIR => $TMP_DIR );

            my $buffer = '';
            while( read( $fh, $buffer, 4096 ) ) {
                print $tmp_fh $buffer;
            }
            close $tmp_fh;
            close $fh;

            if( FLIP_IMAGE ) {
                my $img = Imager->new;
                $img->read(
                    file => $tmp_filename,
                ) or die "Can't open '$tmp_filename': " . $img->errstr;
                $img = $img->flip( dir => 'vh' );
                $img->write(
                    file        => $tmp_filename,
                    type        => 'jpeg',
                    jpegquality => IMG_IMAGER_QUALITY,
                ) or die "Can't write file: " . $img->errstr;
            }

            send_pic( $tmp_filename );
            unlink $tmp_filename;
        }
        else {
            if( $is_open != $prev_is_open ) {
                say "Shop closed, send default closed pic";
                send_pic( DEFAULT_PIC );
            }
            else {
                say "Shop closed, do nothing" if DEBUG;
            }
        }

        $prev_is_open = $is_open;
        return 1;
    };

    return ($input_callback, $lcd_callback, $picture_callback);
}

sub unlock_door
{
    my ($dev) = @_;
    $dev->output_pin( $LED_PIN, 1 );
    $dev->output_pin( $LOCK_PIN, 1 );
    $dev->output_pin( $UNLOCK_PIN, 0 );
    return 1;
}

sub lock_door
{
    my ($dev) = @_;
    $dev->output_pin( $LED_PIN, 0 );
    $dev->output_pin( $LOCK_PIN, 0 );
    $dev->output_pin( $UNLOCK_PIN, 1 );
    return 1;
}


{
    get_sereal_decoder(); # Pre-fetch the Sereal::Decode object

    my $rpi = Device::WebIO::RaspberryPi->new;
    $rpi->set_as_input( $OPEN_SWITCH );
    $rpi->set_as_output( $LCD_POWER_PIN );
    $rpi->set_as_output( $LED_PIN );
    $rpi->set_as_output( $LOCK_PIN );
    $rpi->set_as_output( $UNLOCK_PIN );
    $rpi->output_pin( $LCD_POWER_PIN, 1 );

    # Set pullup resisters for lock/unlock pins.  Have to use 
    # Wiring Pi pin numbering for this
    HiPi::Wiring::pullUpDnControl( $_, WPI_PUD_DOWN )
        for 3, 6;

    lock_door( $rpi );

    # Since Device::WebIO doesn't support sound creation yet, 
    # set piezo ourselves
    HiPi::Wiring::pinMode( $PIEZO_PIN, WPI_PWM_OUTPUT );
    HiPi::Wiring::digitalWrite( $PIEZO_PIN, WPI_LOW );
    HiPi::Wiring::softToneCreate( $PIEZO_PIN );
    HiPi::Wiring::pwmSetMode( WPI_PWM_MODE_MS );


    my $cv = AnyEvent->condvar;
    my $stdin_watcher = AnyEvent->io(
        fh   => \*STDIN,
        poll => 'r',
        cb   => get_tag_input_event( $rpi ),
    );

    my ($input_callback, $lcd_callback, $picture_callback)
        = get_open_status_callbacks( $rpi );
    my $input_timer = AnyEvent->timer(
        after    => 1,
        interval => 0.5,
        cb       => $input_callback,
    );

    my $lcd_timer = AnyEvent->timer(
        after    => 1,
        interval => 1,
        cb       => $lcd_callback,
    );

    my $picture_timer = AnyEvent->timer(
        after    => 1,
        interval => $TAKE_PICTURE_INTERVAL,
        cb       => $picture_callback,
    );

    say "Ready for input";
    $cv->recv;
}
