#!/usr/bin/perl
#
# Check if Open Shop switch is toggled. If so, send Open Shop REST call.
#
use v5.14;
use warnings;
use Device::WebIO::RaspberryPi;
use LWP::UserAgent;

my $POST_URL = 'https://app.tyrion.thebodgery.org/shop_open/';
my $INPUT_PIN = 23;
my $SSL_CERT = undef;


my $UA = LWP::UserAgent->new;
$UA->ssl_opts(
    SSL_ca_file => $SSL_CERT,
) if defined $SSL_CERT;


sub send_open
{
    my ($value) = @_;

    my $url = $POST_URL . ($value ? '1' : '0');
    say "Sending URL: $url";

    my $response = $UA->post( $url );

    if(! $response->is_success ) {
        say "Invalid response to '$url': " . $response->status_line;
    }

    return 1;
}


my $rpi = Device::WebIO::RaspberryPi->new;
$rpi->set_as_input( $INPUT_PIN );
my $in = $rpi->input_pin( $INPUT_PIN );
send_open( $in );
