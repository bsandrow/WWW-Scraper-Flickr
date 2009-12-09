package WWW::Scraper::Flickr;

use strict;
use warnings;

use Carp;
use LWP::UserAgent;
use HTML::Tree;

our $VERSION = 0.1;

our @sizes = qw/o l m s t sq/;
our %size_labels = (
    o => "original",
    l => "large",
    m => "medium",
    s => "small",
    t => "thumbnail",
    sq => "square",
);

sub new {
    my $class = shift;
    my $args  = shift;
    my $self  = {};

    $self->{ua}  = $args->{ua} ? $args->{ua} : _getUserAgent();
    $self->{tree} = HTML::Tree->new();
    $self->{content} = {};
    $self->{verbosity} = 0;

    return bless($self,$class);
}

sub fetch {
    my $self = shift;
    my $args = shift;

    croak "No URL supplied!" unless $args->{url};
    croak "No output directory supplied!" unless $args->{dir};

    my $page = $self->_grabContent($args->{url});
    unless ($page) {
        carp("No content from '$args->{url}'");
        return undef;
    }
    $self->{tree}->parse($page);

    # Fetch all of the metadata
    $self->{content}->{tags}       = $self->_grabTags();
    $self->{content}->{licenseurl} = $self->_grabLicenseUrl();
    $self->{content}->{attriburl}  = $self->_grabAttribUrl();
    $self->{content}->{creator}    = $self->_grabCreator();
    $self->{content}->{uploaddate} = $self->_grabUploadDate();
    $self->{content}->{simpledesc} = $self->_grabSimpleDesc();
    $self->{content}->{canonicalurl}=$self->_grabCanonicalUrl();
    $self->{content}->{title}      = $self->_grabTitle();

    # Fetch the direct iamge urls
    $self->{images} = $self->_grabImageUrls();

    # Download the image
    my $download_url = $self->_getBestUrl();
    my ($filename)   = ($download_url =~ m{/([^/]+)$});
    $self->{ua}->get($download_url, ':content_file' => "$args->{dir}/$filename");
    $self->{file}->{fullpath} = "$args->{dir}/$filename";

    $self->_buildMetadataOptions();
    $self->_cleanup();

    # Return the fullpath to the file.
    return $self->{file}->{fullpath};
}

sub toggleVerbosity {
    my $self      = shift;
    my $verbosity = shift;
    $self->{verbosity} = !($self->{verbosity}) if !defined($verbosity);
    $self->{verbosity} = $verbosity;
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
    print STDERR $response->status_line, "\n" if $self->{verbosity};
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

sub _grabCanonicalUrl {
    my $self     = shift;
    my @elements = $self->{tree}->look_down(
        '_tag'  => 'link',
        'rel'   => 'canonical',
    );
    die "Bad content! More than one canonical link defined!" if scalar @elements > 1;
    return $elements[0]->attr('href');
}

sub _grabTitle {
    my $self     = shift;
    my @elements = $self->{tree}->look_down(
        '_tag' => 'meta',
        'name' => 'title',
    );
    die "Bad content! More than one title defined!" if scalar @elements > 1;
    return $elements[0]->attr('content');
}

sub _grabImageUrls {
    my $self     = shift;
    my $urls     = {};
    my $sizeUrl  = $self->{content}->{canonicalurl} . "/sizes/";

    for (@sizes) {
        my $response = $self->{ua}->get($sizeUrl . "$_/");
        next unless $response->is_success;
        my $tree = HTML::TreeBuilder->new_from_content($response->content);
        my @elements = $tree->look_down(sub{
                $_[0]->tag() eq 'a' and
                join(' ', @{$_[0]->content()}) =~ m/Download/ and
                $_[0]->attr('href') =~ m/static\.flickr\.com/
        });
        die "Bad content! More than one download link found!" if scalar @elements > 1;
        $urls->{$_} = $elements[0]->attr('href');
    }

    return $urls;
}

sub _getBestUrl {
    my $self = shift;
    for (@sizes) {
        return $self->{images}->{$_} if $self->{images}->{$_};
    }
    return undef;
}

sub _buildMetadataOptions {
    my $self = shift;

    my @options = map { "-Keywords+=$_" } @{ $self->{content}->{tags} };
    push @options, "-CopyrightNotice=\"Copyright $self->{content}->{creator} [license=$self->{content}->{licenseurl}] [flickr=$self->{content}->{attriburl}]\"";
    push @options, "-Caption-Abstract=\"[title] $self->{content}->{title} [/title][description] $self->{content}->{simpledesc} [/description]\"";
    push @options, "-overwrite_original";
    push @options, "-q";
    push @options, $self->{file}->{fullpath};

    system('exiftool',@options);
}

sub _cleanup {
    my $self = shift;

    $self->{tree}->delete;
    $self->{tree} = HTML::Tree->new();

    $self->{images}  = {};
    $self->{content} = {};

    return;
}
1;
