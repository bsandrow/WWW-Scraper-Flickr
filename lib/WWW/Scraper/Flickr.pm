package WWW::Scraper::Flickr;

use strict;
use warnings;

use LWP::UserAgent;
use Carp qw/
    croak
/;

our $VERSION = 0.1;

sub new {
    my $class = shift;
    my $args  = shift;
    my $self  = {};

    $self->{ua} = $args->{ua} ? $args->{ua} : _getUserAgent();

    return bless($self,$class);
}

sub _getUserAgent {
    my $ua = LWP::UserAgent->new();
    $ua->timeout(10);
    $ua->env_proxy;
    return $ua;
}

sub fetch {
    my $self = shift;
    my $args = shift;

    croak "No URL supplied!" unless $args->{url};
    croak "No output directory supplied!" unless $args->{dir};

    # XXX need to return path to the image file or undef
    return;
}
