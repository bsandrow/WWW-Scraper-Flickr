package WWW::Scraper::Flickr;

use strict;
use warnings;

use Carp;
use LWP::UserAgent;
use HTML::Tree;
use JSON::XS;
use HTTP::Date;
use URI;
use URI::QueryParam;

our $VERSION = 0.2;

our @sizes = qw/o l m s t sq/;
our %size_labels = ( # more or less obsolete
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

    $self->{content}->{html} = $self->_grabContent($args->{url});
    unless ($self->{content}->{html}) {
        carp("No content from '$args->{url}'");
        return undef;
    }

    $self->_parseJSON(); #  sets as many metadata fields as possible

#   $self->{tree}->parse($self->{content}->{html});

    # Fetch all of the metadata
#   $self->{content}->{tags}       = $self->_grabTags();
#   $self->{content}->{licenseurl} = $self->_grabLicenseUrl();
#   $self->{content}->{attriburl}  = $self->_grabAttribUrl();
#   $self->{content}->{creator}    = $self->_grabCreator();
#   $self->{content}->{uploaddate} = $self->_grabUploadDate();
#   $self->{content}->{simpledesc} = $self->_grabSimpleDesc();
#   $self->{content}->{canonicalurl}=$self->_grabCanonicalUrl();
#   $self->{content}->{title}      = $self->_grabTitle();

    # Fetch the direct iamge urls
#   $self->{images} = $self->_grabImageUrls();

	if($args->{'user-dir'}){
		my $user_dir = $self->{content}->{creator};
		unless($user_dir){
			$args->{url} =~ /www\.flickr\.com\/photos\/([^\/]+)\//;
			$user_dir = $1;
		}
		print STDERR " to per-user directory ". $user_dir ." in ". $args->{dir} ."\n" if $self->{verbosity};
		$args->{dir} = $args->{dir} .'/'. $user_dir;

		mkdir($args->{dir}) unless -d $args->{dir};
	}

    # Download the image
    my $download_url = $self->_getBestUrl();
    die "WWW::Scraper::Flickr: error finding download_url! \n". $self->{content}->{html} unless $download_url;
    my ($filename)   = ($download_url =~ m{/([^/]+)$});
    $self->{file}->{dir} = $args->{dir};
    $self->{file}->{fullpath} = "$args->{dir}/$filename";
	if(-f "$args->{dir}/$filename"){
		print STDERR "WWW::Scraper::Flickr: file ". "$args->{dir}/$filename" ." exists! skipping\n";
		return $self->{file}->{fullpath};
	}
    $self->{ua}->get($download_url, ':content_file' => "$args->{dir}/$filename");
	if($self->{content}->{is_video}){
		$self->fetch_video();
	}

    $self->_buildExiftoolOptionsAndExecute();
    $self->_setTimestamp();
    $self->_cleanup();

    # Return the fullpath to the file.
    return $self->{file}->{fullpath};
}

sub fetch_video {
	my $self = shift;

	my ($id,$secret) = $self->{sizes}->{s}->{url} =~ /\/(\d+)_([^_]+)_\w\.jpg/;
	return unless $id && $secret;
	print STDERR "WWW::Scraper::Flickr::fetch_video: [video] id:$id secret:$secret \n";

	# needed to get node_id
	my $url_mtl = "https://www.flickr.com/apps/video/video_mtl_xml.gne?v=x&photo_id=". $id ."&secret=". $secret ."&bitrate=700&target=_self";
	$self->{ua}->cookie_jar({ file => "cookies.txt" }); # CND auth needs cookies
	my $response = $self->{ua}->get($url_mtl);
	unless($response->is_success){
		print STDERR die $response->status_line;
		return;
	}

	my $xml = $response->decoded_content();
	$xml =~ /\Q<Item id="id">\E([^<]+)<\/Item>/;
	my $node_id = $1;
	return unless $node_id;
	print STDERR "WWW::Scraper::Flickr::fetch_video: [video] node_id:$node_id secret:$secret \n";

	# provides CDN video file URI
	my $url_playlist = "https://www.flickr.com/video_playlist.gne?node_id=". $node_id ."&mode=playlist&bitrate=700&secret=". $secret ."&rd=video.yahoo.com&noad=1";
	$response = $self->{ua}->get($url_playlist);
	unless($response->is_success){
		print STDERR die $response->status_line;
		return;
	}

	$xml = $response->decoded_content();
	my ($host,$path) = $xml =~ /\Q<STREAM APP="\E([^"]+)" FULLPATH="([^"]+)" /;
	return unless $host && $path;
	print STDERR "WWW::Scraper::Flickr::fetch_video: [video] host:$host path:$path \n";

	my $uri = URI->new($host . $path);
	my $filename = $uri->query_param("fn");
	print STDERR "WWW::Scraper::Flickr::fetch_video: [video] filename:$filename path_local:$self->{file}->{dir} / $filename\n";

## 401 unauthorized...!?
	$response = $self->{ua}->get($host . $path, ':content_file' => $self->{file}->{dir} ."/". $filename);
	unless($response->is_success){
		print STDERR die $response->status_line;
		return;
	}
}

sub collection {
	my $self = shift;
	my @pages = @_;

	my $cnt = 1;
	my $max = 1;
	my @photos;
	for my $url (@pages){
		# switch to mobile site as it exposes proper
		$url =~ s/\/\/www\.flickr\.com\//\/\/m\.flickr\.com\//;

		print STDERR "WWW::Scraper::Flickr::collection: $cnt: fetching $url\n";
		my $response = $self->{ua}->get($url);

		unless($response->is_success){
			print STDERR die $response->status_line;
			next;
		}

		my $html = $response->decoded_content;

		# get pagination limits
		if($url =~ /\/$/){ # $_ =~ /page1$/
			$html =~ /\t\t\tPage \d+ of (\d+)/;
			$max = $1;

			if($max && $max > 1){
				for my $i (2 .. $max){
					push(@pages, $url .'page'. $i);
				}
			}
			print Dumper(\@pages) if $self->{verbosity} && $self->{verbosity} > 2;

			print STDERR "WWW::Scraper::Flickr::collection: ". ($max||'(not found!)') ." pages\n" if $self->{verbosity};
		}

		
		# get photos on this page
	#	my @found_photos = $html =~ /\sbackground-image: url(\/\/[^\.]+\.staticflickr\.com\/\d+\/\d+\/(\d+)_[^_]+_[^\.]\.jpg)" data-view-signature=/g;
	#	my @found_photos = $html =~ /\sbackground-image: url(\/\/([^\)]+))" data-view-signature=/g;
		my @found_photos = $html =~ /\/(\d+)_[^_]+_[sz]\.jpg/g;
		print Dumper(\@found_photos) if $self->{verbosity} && $self->{verbosity} > 2;

		push(@photos,@found_photos);
		$cnt++;
	}

	my %dedup;
	for(@photos){ $dedup{$_} = 1; }
	@photos = ();
	for(keys %dedup){
		push(@photos, $_[0] . $_ .'/');
	}
	# print Dumper(\@photos) if $self->{verbosity};

	print STDERR "WWW::Scraper::Flickr::collection: ". scalar(@photos) ." photos \n";
	return @photos;
}

# works, but flickr exposes only 1/3 of all images in HTML via the desktop version
sub collection_desktop {
	my $self = shift;
	my @pages = @_;

	my $cnt = 1;
	my $max = 1;
	my @photos;
	for my $url (@pages){
		print STDERR "WWW::Scraper::Flickr::collection: $cnt: fetching $url\n";
		my $response = $self->{ua}->get($url);

		unless($response->is_success){
			print STDERR die $response->status_line;
			next;
		}

		my $html = $response->decoded_content;

		# get pagination limits
		if($url =~ /\/$/){ # $_ =~ /page1$/
			my @pagination = $html =~ /<a href="\/photos\/[^\/]+\/page(\d+)"\s+data-track="pagination/g;
			for(@pagination){ $max = $_ if $_ > $max }
			# print Dumper(\@pagination);

			if($max > 1){
				for my $i (2 .. $max){
					push(@pages, $url .'page'. $i);
				}
			}
			print Dumper(\@pages) if $self->{verbosity} && $self->{verbosity} > 2;

			print STDERR "WWW::Scraper::Flickr::collection: $cnt of $max pages\n" if $self->{verbosity};
		}

		
		# get photos on this page
	#	my @found_photos = $html =~ /\sbackground-image: url(\/\/[^\.]+\.staticflickr\.com\/\d+\/\d+\/(\d+)_[^_]+_[^\.]\.jpg)" data-view-signature=/g;
	#	my @found_photos = $html =~ /\sbackground-image: url(\/\/([^\)]+))" data-view-signature=/g;
		my @found_photos = $html =~ /\/(\d+)_[^_]+_[sz]\.jpg/g;
		print Dumper(\@found_photos);

		push(@photos,@found_photos);
		$cnt++;
	}

	my %dedup;
	for(@photos){ $dedup{$_} = 1; }
	@photos = ();
	for(keys %dedup){
		push(@photos, $_[0] . $_ .'/');
	}
	print Dumper(\@photos);

	return @photos;
}

sub toggleVerbosity {
    my $self      = shift;
    my $verbosity = shift;
    $self->{verbosity} = !($self->{verbosity}) if !defined($verbosity);
    $self->{verbosity} = $verbosity;
    if($verbosity){
	require Data::Dumper;
	Data::Dumper->import();
    }
}

sub setProxy {
	my $self  = shift;
	my $proxy = shift;
	$self->{ua}->proxy(['http','https'] => $proxy);
	print STDERR "WWW::Scraper::Flickr::setProxy: proxy set to ". $proxy ."\n" if $self->{verbosity};
}

sub setUserAgent {
	my $self      = shift;
	my $ua_string = shift;
	$self->{ua}->agent($ua_string);
	print STDERR "WWW::Scraper::Flickr::setUserAgent: ua-string set to ". $self->{ua}->agent() ."\n" if $self->{verbosity};
}

sub _getUserAgent {
    my $ua = LWP::UserAgent->new();
    $ua->timeout(10);
    $ua->env_proxy;
    $ua->agent("Mozilla/5.0");
    $ua->default_header('Accept-Encoding' => scalar HTTP::Message::decodable());
    $ua->default_header('Accept-Language' => 'en-EN,en-GB;q=0.8,en;q=0.5');
    return $ua;
}

sub _grabContent {
    my $self = shift;
    my $url  = shift;
    my $response = $self->{ua}->get($url);
    print STDERR " ". $response->status_line, "\n" if $self->{verbosity};
    return undef unless $response->is_success;
    return $response->decoded_content(charset => 'none'); # leave it utf-8 encoded, for JSON decode
}

sub _parseJSON {
	my $self = shift;

	## YT-specific json parsing
	my $json;
	for(split "\n", $self->{content}->{html} ){
		next unless $_;
		if( $_ =~ /modelExport\:\s*({.*})/ ){
			$json = eval { JSON::XS::decode_json($1) };
			print STDERR $@ if $@;
			last;
		}
	}

	if($json && $json->{'photo-models'} && ref($json->{'photo-models'}) eq 'ARRAY'){
		$self->{sizes} = $json->{'photo-models'}->[0]->{sizes} if $json->{'photo-models'}->[0]->{sizes};

#		$self->{content}->{tags}       = $self->_grabTags();
#		$self->{content}->{licenseurl} = $self->_grabLicenseUrl();
#		$self->{content}->{attriburl}  = $self->_grabAttribUrl();
		$self->{content}->{creator}    = $json->{'photo-models'}->[0]->{owner}->{username};
		$self->{content}->{creator_id} = $json->{'photo-models'}->[0]->{owner}->{id};
		$self->{content}->{title}      = $json->{'photo-models'}->[0]->{title};

		if($json && $json->{'photo-models'}->[0]->{'mediaType'} && $json && $json->{'photo-models'}->[0]->{'mediaType'} eq 'video'){
			print STDERR "WWW::Scraper::Flickr: is a video!\n";
			$self->{content}->{is_video} = 1;
		}
	}

	if($json && $json->{'photo-stats-models'} && ref($json->{'photo-stats-models'}) eq 'ARRAY'){
		$self->{content}->{uploadepoch} = $json->{'photo-stats-models'}->[0]->{'datePosted'};
		$self->{content}->{uploaddate} = HTTP::Date::time2str($self->{content}->{uploadepoch});
	}

	if($json && $json->{'photo-head-meta-models'} && ref($json->{'photo-head-meta-models'}) eq 'ARRAY'){
		$self->{content}->{canonicalurl} = $json->{'photo-head-meta-models'}->[0]->{'og:url'};
		$self->{content}->{simpledesc} = $json->{'photo-head-meta-models'}->[0]->{'og:description'};
	}

	print Dumper($json) if $self->{verbosity} && $self->{verbosity} > 2;
}

sub _grabTags {
    my $self = shift;
    my ($keywords) = $self->{tree}->look_down(
        '_tag' => 'meta',
        'name' => 'keywords',
    );
	my @tags = split(/, /, $keywords->attr('content')) if $keywords;
    return \@tags;
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
    return $elements[0] ? "http://www.flickr.com" . $elements[0]->attr('href') : undef;
}

sub _grabCreator {
    my $self     = shift;
    my @elements = $self->{tree}->look_down(
        '_tag'     => 'b',
        'property' => 'foaf:name',
    );
    die "Bad content! Multiple elements tagged with 'foaf:name'." if scalar @elements > 1;
    return $elements[0] ? join ' ', @{$elements[0]->content()} : undef;
}

sub _grabUploadDate {
    my $self     = shift;
    my @elements = $self->{tree}->look_down(
        '_tag'      => 'a',
        'property'  => qr/dc:date/,
    );
    die "Bad content! Multiple items tagged with dc:date." if scalar @elements > 1;
    return $elements[0] ? join ' ', @{$elements[0]->content()} : undef;
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
		$_[0]->attr('href') =~ m/staticflickr\.com/
	});
	die "Bad content! More than one download link found!" if scalar @elements > 1;
	$urls->{$_} = $elements[0]->attr('href');
	}

	return $urls;
}

sub _getBestUrl {
	my $self = shift;

	if($self->{sizes}){
		my @by_size = map { $self->{sizes}->{$_} } sort { $self->{sizes}->{$b}->{width} <=> $self->{sizes}->{$a}->{width} } (keys %{ $self->{sizes} });
		my $best = ($by_size[0]->{url} =~ /^\/\//) ? 'http:'. $by_size[0]->{url} : $by_size[0]->{url};
		if($self->{verbosity}){
			print STDERR "WWW::Scraper::Flickr::_getBestUrl: ". Dumper(\@by_size) ."\n" if $self->{verbosity} > 1;
			print STDERR "WWW::Scraper::Flickr::_getBestUrl: best: $best (".$by_size[0]->{width}."x".$by_size[0]->{height}.")\n" if $self->{verbosity};
		}
		return $best;
	}else{
		# legacy mode, never used
		for (@sizes) {
			return $self->{images}->{$_} if $self->{images}->{$_};
		}
	}

	return undef;
}

sub _buildExiftoolOptionsAndExecute {
    my $self = shift;

    my @options = map { "-Keywords+=$_" } @{ $self->{content}->{tags} } if $self->{content}->{tags};
    push @options, "-CopyrightNotice=\"Copyright $self->{content}->{creator} [license=$self->{content}->{licenseurl}] [flickr=$self->{content}->{attriburl}]\"" if $self->{content}->{creator} && $self->{content}->{licenseurl} && $self->{content}->{attriburl};
    push @options, '-IPTC:Headline="'. $self->{content}->{title} .'"' if $self->{content}->{title};
    push @options, '-IPTC:By-line="'. $self->{content}->{creator} .'"' if $self->{content}->{creator};
    push @options, '-IPTC:Caption-Abstract="'. $self->{content}->{simpledesc} .'"' if $self->{content}->{simpledesc};
    push @options, '-Comment="Flickr URL: '. $self->{content}->{canonicalurl} .'"' if $self->{content}->{canonicalurl};
#   push @options, "-Caption-Abstract=\"[title] $self->{content}->{title} [/title][description] $self->{content}->{simpledesc} [/description]\"" if $self->{content}->{title} && $self->{content}->{simpledesc};
    push @options, "-overwrite_original";
#   push @options, "-q";
    push @options, $self->{file}->{fullpath};
    # print "WWW::Scraper::Flickr::_buildExiftoolOptionsAndExecute: @options";
    system('exiftool',@options);
    @options = ();
}

sub _setTimestamp {
	my $self = shift;

	if($self->{content}->{uploadepoch}){
		# could be done by exiftool, but...
		utime(0, $self->{content}->{uploadepoch}, $self->{file}->{fullpath});
		print STDERR "WWW::Scraper::Flickr::_setTimestamp: uploaded on $self->{content}->{uploaddate} \n" if $self->{verbosity};
	}
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

=head1 NAME

WWW::Scraper::Flickr - A flickr.com scraper

=head1 SYNOPSIS

Module to download images from flickr.com with information from the photo page
inserted into the image file metadata.

=head1 VERSION

Version 0.2

=head1 AUTHOR

Brandon Sandrowicz <brandon@sandrowicz.org>

=head1 License

MIT License

=cut
