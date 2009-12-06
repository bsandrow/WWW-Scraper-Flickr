package WWW::Scraper::Flickr;

use strict;
use warnings;

use Data::Dumper;
use LWP::UserAgent;
use HTML::Tree;
use Carp qw/croak/;

our $VERSION = 0.1;

sub new {
    my $class = shift;
    my $args  = shift;
    my $self  = {};

    $self->{ua}  = $args->{ua} ? $args->{ua} : _getUserAgent();
    $self->{tree}= HTML::Tree->new();
    $self->{content} = {};

    return bless($self,$class);
}

sub fetch {
    my $self = shift;
    my $args = shift;

    croak "No URL supplied!" unless $args->{url};
    croak "No output directory supplied!" unless $args->{dir};

    my $page = $self->_grabContent($args->{url});
    die "No content" unless $page;
    $self->{tree}->parse($page);

    $self->{content}->{tags}       = $self->_grabTags();
    $self->{content}->{licenseurl} = $self->_grabLicenseUrl();
    $self->{content}->{attriburl}  = $self->_grabAttribUrl();
    $self->{content}->{creator}    = $self->_grabCreator();
    $self->{content}->{uploaddate} = $self->_grabUploadDate();
    $self->{content}->{simpledesc} = $self->_grabSimpleDesc();

    # XXX need to return path to the image file or undef
    return;
}

sub _getUserAgent {
    my $ua = LWP::UserAgent->new();
    $ua->timeout(10);
    $ua->env_proxy;
    $ua->agent("Mozilla/5.0");
    return $ua;
}

sub _grabContent {
    my $self = shift;
    my $url  = shift;
    my $response = $self->{ua}->get($url);
    return undef unless $response->is_success;
    return $response->content;
}

sub _grabTags {
    my $self = shift;
    my ($keywords) = $self->{tree}->look_down(
        '_tag' => 'meta',
        'name' => 'keywords',
    );
    return [split /, /, $keywords->attr('content')];
}

sub _grabLicenseUrl {
    my $self = shift;
    my @elements = $self->{tree}->look_down(
        '_tag' => 'a',
        'rel'  => qr/cc:license/,
    );
    die "Error parsing! There are mutliple elements with 'cc:license'." if scalar @elements > 1;
    return $elements[0]->attr('href');
}

sub _grabAttribUrl {
    my $self = shift;
    my (@elements) = $self->{tree}->look_down(
        '_tag' => 'a',
        'rel'  => qr/cc:attributionURL/,
    );
    die "Bad content! Multiple cc:attributionURL elements!" if scalar @elements > 1;
    return "http://www.flickr.com" . $elements[0]->attr('href');
}

sub _grabCreator {
    my $self     = shift;
    my @elements = $self->{tree}->look_down(
        '_tag'     => 'b',
        'property' => 'foaf:name',
    );
    die "Bad content! Multiple elements tagged with 'foaf:name'." if scalar @elements > 1;
    return join ' ', @{$elements[0]->content()};
}

sub _grabUploadDate {
    my $self     = shift;
    my @elements = $self->{tree}->look_down(
        '_tag'      => 'a',
        'property'  => qr/dc:date/,
    );
    die "Bad content! Multiple items tagged with dc:date." if scalar @elements > 1;
    return join ' ', @{$elements[0]->content()};
}

sub _grabSimpleDesc {
    # called 'simple' desc because it strips out a lot of context that the
    # 'full' description could have (like links). Though we are converting to
    # text to insert into metadata anyways, keeping urls in there by converting
    # <a href="google">Google</a> -> (Google)[google] would help out in *not*
    # loosing a bunch of content. At some point a _grabLongDesc() will make
    # it's way into here.
    my $self = shift;
    my @elements = $self->{tree}->look_down(
        '_tag' => 'meta',
        'name' => 'description',
    );
    die "Bad content! Multiple <meta name=\"description\"...> tags!" if scalar @elements > 1;
    return $elements[0]->attr('content');
}

1;
