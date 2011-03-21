package Slim::Music::Info;

# $Id: Info.pm 23322 2008-09-28 08:26:29Z adrian $

# SqueezeCenter Copyright 2001-2007 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

=head1 NAME

Slim::Music::Info

=head1 DESCRIPTION

L<Slim::Music::Info>

=cut

use strict;

use File::Path;
use File::Spec::Functions qw(:ALL);
use Path::Class;
use Scalar::Util qw(blessed);
use Tie::Cache::LRU;

use Slim::Formats;
use Slim::Music::TitleFormatter;
use Slim::Player::ProtocolHandlers;
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::OSDetect;
use Slim::Utils::Strings qw(string);
use Slim::Utils::Text;
use Slim::Utils::Unicode;
use Slim::Utils::Prefs;

# three hashes containing the types we know about, populated by the loadTypesConfig routine below
# hash of default mime type index by three letter content type e.g. 'mp3' => audio/mpeg
our %types = ();

# hash of three letter content type, indexed by mime type e.g. 'text/plain' => 'txt'
our %mimeTypes = ();

# hash of three letter content types, indexed by file suffixes (past the dot)  'aiff' => 'aif'
our %suffixes = ();

# hash of types that the slim server recoginzes internally e.g. aif => audio
our %slimTypes = ();

# Make sure that these can't grow forever.
tie our %currentTitles, 'Tie::Cache::LRU', 64;
tie our %currentBitrates, 'Tie::Cache::LRU', 64;

# text cache for non clients
our $musicInfoTextCache = undef;

our %currentTitleCallbacks = ();

# Save our stats.
tie our %isFile, 'Tie::Cache::LRU', 16;

# No need to do this over and over again either.
tie our %urlToTypeCache, 'Tie::Cache::LRU', 16;

my $log = logger('database.info');

my $prefs = preferences('server');

sub init {

	# Allow external programs to use Slim::Utils::Misc, without needing
	# the entire DBI stack.
	require Slim::Schema;
	Slim::Schema->init;

	if (!Slim::Music::TitleFormatter::init()) {
		return 0;
	}

	if (!loadTypesConfig()) {
		return 0;
	}

	if (!Slim::Formats->init()) {
		return 0;
	}

	return 1;
}

sub loadTypesConfig {
	my @typesFiles = ();

	$log->info("Loading config file...");

	# custom types file allowed at server root or root of plugin directories
	for my $baseDir (Slim::Utils::OSDetect::dirsFor('types')) {

		push @typesFiles, catdir($baseDir, 'types.conf');
		push @typesFiles, catdir($baseDir, 'custom-types.conf');
	}

	foreach my $baseDir (Slim::Utils::PluginManager->pluginRootDirs()) {

		push @typesFiles, catdir($baseDir, 'custom-types.conf');
	}

	foreach my $typeFileName (@typesFiles) {

		if (open my $typesFile, $typeFileName) {

			for my $line (<$typesFile>) {

				# get rid of comments and leading and trailing white space
				$line =~ s/#.*$//;
				$line =~ s/^\s//;
				$line =~ s/\s$//;
	
				if ($line =~ /^(\S+)\s+(\S+)\s+(\S+)\s+(\S+)/) {

					my $type = $1;
					my @suffixes  = split ',', $2;
					my @mimeTypes = split ',', $3;
					my @slimTypes = split ',', $4;
					
					foreach my $suffix (@suffixes) {
						next if ($suffix eq '-');
						$suffixes{$suffix} = $type;
					}
					
					foreach my $mimeType (@mimeTypes) {
						next if ($mimeType eq '-');
						$mimeTypes{$mimeType} = $type;
					}

					foreach my $slimType (@slimTypes) {
						next if ($slimType eq '-');
						$slimTypes{$type} = $slimType;
					}
					
					# the first one is the default
					if ($mimeTypes[0] ne '-') {
						$types{$type} = $mimeTypes[0];
					}				
				}
			}

			close $typesFile;
		}
	}

	if (scalar keys %types > 0) {

		return 1;
	}

	return 0;
}

sub playlistForClient {
	my $client = shift;

	return Slim::Schema->rs('Playlist')->getPlaylistForClient($client);
}

sub clearFormatDisplayCache {
	my $format = shift; # if set only clear cached formats including this string

	if ($format) {
		# prune matching entries from non client cache
		for my $key ( keys %$musicInfoTextCache ) {
			delete $musicInfoTextCache->{$key} if ($key =~ /$format/);
		}

		# prune matching entries from client caches
		for my $client ( Slim::Player::Client::clients() ) {
			if (my $cache = $client->musicInfoTextCache) {
				for my $key ( keys %$cache ) {
					delete $cache->{$key} if ($key =~ /$format/);
				}
			}
		}

	} else {
		# remove all cached entries
		$musicInfoTextCache = undef;

		foreach my $client ( Slim::Player::Client::clients() ) {
			$client->musicInfoTextCache(undef);
		}

		%currentTitles   = ();
		%currentBitrates = ();
	}
}

sub updateCacheEntry {
	my $url = shift;
	my $cacheEntryHash = shift;

	if (!defined($url)) {

		logBacktrace("No URL passed!");
		Data::Dump::dump($cacheEntryHash) if !$::quiet;
		return;
	}

	if (!isURL($url)) { 

		logBacktrace("Non-URL passed from caller ($url)");
		return;
	}

	my $list = $cacheEntryHash->{'LIST'} || [];

	my $playlist = Slim::Schema->rs('Playlist')->updateOrCreate({
		'url'        => $url,
		'attributes' => $cacheEntryHash,
	});

	if (ref($list) eq 'ARRAY' && scalar @$list && blessed($playlist) && $playlist->can('setTracks')) {

		$playlist->setTracks($list);
	}

	return $playlist;
}

##################################################################################
# this routine accepts both our three letter content types as well as mime types.
# if neither match, we guess from the URL.
sub setContentType {
	my $url = shift;
	my $type = shift;

	if ($type =~ /(.*);(.*)/) {

		# content type has ";" followed by encoding
		$log->info("Truncating content type. Was: $type, now: $1");

		# TODO: remember encoding as it could be useful later
		$type = $1; # truncate at ";"
	}

	$type = lc($type);

	if ($types{$type}) {

		# we got it

	} elsif ($mimeTypes{$type}) {

		$type = $mimeTypes{$type};

	} else {

		my $guessedtype = typeFromPath($url);

		if ($guessedtype ne 'unk') {
			$type = $guessedtype;
		}
	}

	# Update the cache set by typeFrompath as well.
	$urlToTypeCache{$url} = $type;
	
	$log->info("Content-Type for $url is cached as $type");

	# Commit, since we might use it again right away.
	return Slim::Schema->rs('Track')->updateOrCreate({
		'url'        => $url,
		'attributes' => { 'CT' => $type },
		'commit'     => 1,
		'readTags'   => isRemoteURL($url) ? 0 : 1,
	});
}

sub title {
	my $url = shift;

	# Use objectForUrl, as updateOrCreate() without an attribute hash will
	# guess tags on files, which is incorrect.
	my $track = Slim::Schema->rs('Track')->objectForUrl({
		'url'      => $url,
		'create'   => 1,
		'commit'   => 1,
		'readTags' => isRemoteURL($url) ? 0 : 1,
	});

	return $track->title;
}

sub setTitle {
	my $url = shift;
	my $title = shift;

	$log->info("Adding title $title for $url");

	# Only readTags if we're not a remote URL. Otherwise, we'll
	# overwrite the title with the URL.
	return Slim::Schema->rs('Track')->updateOrCreate({
		'url'        => $url,
		'attributes' => { 'TITLE' => $title },
		'readTags'   => isRemoteURL($url) ? 0 : 1,
		'commit'     => 1,
	});
}

sub getCurrentBitrate {
	my $url = shift || return undef;
	
	if ( ref $url && $url->can('url') ) {
		$url = $url->url;
	}

	return $currentBitrates{$url} || undef;
}

sub getBitrate {
	my $url = shift || return undef;
	
	my $track = Slim::Schema->rs('Track')->objectForUrl({
		'url' => $url,
	});
	
	return ( blessed $track ) ? $track->bitrate : undef;
}

sub setBitrate {
	my $url     = shift;
	my $bitrate = shift;
	my $vbr     = shift || undef;

	my $track   = Slim::Schema->rs('Track')->updateOrCreate({
		'url'        => $url,
		'readTags'   => 1,
		'commit'     => 1,
		'attributes' => { 
			'BITRATE'   => $bitrate,
			'VBR_SCALE' => $vbr,
		},
	});
	
	# Cache the bitrate string so it will appear in TrackInfo
	$currentBitrates{$url} = $track->prettyBitRate;

	return $track;
}

sub setDuration {
	my $url      = shift;
	my $duration = shift;

	Slim::Schema->rs('Track')->updateOrCreate({
		'url'        => $url,
		'readTags'   => 1,
		'commit'     => 1,
		'attributes' => { 
			'SECS' => $duration,
		},
	});
}

sub getDuration {
	my $url = shift;
	
	my $track = Slim::Schema->rs('Track')->objectForUrl({
		'url' => $url,
	});
	
	return ( blessed $track ) ? $track->secs : undef;
}

# Constant bitrates
my %cbr = map { $_ => 1 } qw(32 40 48 56 64 80 96 112 128 160 192 224 256 320);

sub setRemoteMetadata {
	my ( $url, $meta ) = @_;
	
	my $attr = {};
	
	if ( $meta->{title} ) {
		$attr->{TITLE} = $meta->{title};
		
		setCurrentTitle( $url, $meta->{title} );
	}
	
	if ( my $type = $meta->{ct} ) {
		if ( $type =~ /(.*);(.*)/ ) {
			# content type has ";" followed by encoding
			$log->info("Truncating content type. Was: $type, now: $1");
			# TODO: remember encoding as it could be useful later
			$type = $1; # truncate at ";"
		}

		$type = lc($type);

		if ( $types{$type} ) {
			# we got it
		}
		elsif ($mimeTypes{$type}) {
			$type = $mimeTypes{$type};
		}
		else {
			my $guessedtype = typeFromPath($url);

			if ( $guessedtype ne 'unk' ) {
				$type = $guessedtype;
			}
		}

		# Update the cache set by typeFrompath as well.
		$urlToTypeCache{$url} = $type;
		
		$attr->{CT} = $type;
	}
	
	if ( $meta->{secs} ) {
		my $secs = $meta->{secs};
		
		# Bug 7470: duration may be in hh:mm:ss format
		if ($secs =~ /\d+:\d+/) {
			
			my @F = split(':', $secs);
			$secs = $F[-1] + $F[-2] * 60;
			if (@F > 2) {$secs += $F[-3] * 3600;}
		}
		
		$attr->{SECS} = $secs;
	}
	
	if ( $meta->{bitrate} ) {
		$attr->{BITRATE}   = $meta->{bitrate} * 1000;
		$attr->{VBR_SCALE} = ( exists $cbr{ $meta->{bitrate} } ) ? undef : 1;
	}
	
	if ( $log->is_debug ) {
		$log->debug( "Updating metadata for $url: " . Data::Dump::dump($attr) );
	}

	my $track = Slim::Schema->rs('Track')->updateOrCreate( {
		url        => $url,
		attributes => $attr,
		readTags   => 0,
		commit     => 1,
	} );
	
	if ( $meta->{bitrate} ) {
		# Cache the bitrate string so it will appear in TrackInfo
		$currentBitrates{$url} = $track->prettyBitRate;
	}
	
	return $track;
}

sub setCurrentTitleChangeCallback {
	my $callbackRef = shift || return;

	if (ref($callbackRef) eq 'CODE') {

		$currentTitleCallbacks{$callbackRef} = $callbackRef;

		return 1;
	}

	return 0;
}

sub clearCurrentTitleChangeCallback {
	my $callbackRef = shift || return;

	delete $currentTitleCallbacks{$callbackRef};
}

sub setCurrentTitle {
	my $url = shift;
	my $title = shift;

	if (($currentTitles{$url} || '') ne ($title || '')) {
		no strict 'refs';
		
		for my $changeCallback (values %currentTitleCallbacks) {

			if (ref($changeCallback) eq 'CODE') {
				&$changeCallback($url, $title);
			}
		}
	}

	$currentTitles{$url} = $title;
}

# Can't do much if we don't have a url.
sub getCurrentTitle {
	my $client = shift;
	my $url    = shift || return undef;
	my $web    = shift || 0;
	
	if ( blessed($client) ) {
		# Let plugins control the current title if they want
		my $handler = Slim::Player::ProtocolHandlers->handlerForURL($url);
		if ( $handler && $handler->can('getCurrentTitle') ) {
		    if ( my $title = $handler->getCurrentTitle( $client, $url ) ) {
		        return $title;
	        }
	    }
	}
	
	if ( $currentTitles{$url} ) {
		return $currentTitles{$url};
	}
	
	# If the request came from the web, we don't want to format the title
	# using the client formatting pref
	if ( $web ) {
		return standardTitle( undef, $url ); 
	}

	return standardTitle( $client, $url );
}

# Sets a new metadata title but delays the set
# according to the amount of audio data in the
# player's buffer.
sub setDelayedTitle {
	my ( $client, $url, $newTitle ) = @_;
	
	my $log = logger('player.streaming.direct') || logger('player.streaming.remote');
	
	my $metaTitle = $client->metaTitle || '';
	
	if ( $newTitle && ( $metaTitle ne $newTitle ) ) {
		
		# Some mp3 stations can have 10-15 seconds in the buffer.
		# This will delay metadata updates according to how much is in
		# the buffer, so title updates are more in sync with the music
		my $bitrate = Slim::Music::Info::getBitrate($url) || 128000;
		my $delay   = 0;
		
		if ( $bitrate > 0 ) {
			my $decodeBuffer = $client->bufferFullness() / ( int($bitrate / 8) );
			my $outputBuffer = $client->outputBufferFullness() / (44100 * 8);
		
			$delay = $decodeBuffer + $outputBuffer;
		}
		
		# No delay on the initial metadata
		if ( !$metaTitle ) {
			$delay = 0;
		}
		
		$log->info("Delaying metadata title set by $delay secs");
		
		$client->metaTitle( $newTitle );
		
		Slim::Utils::Timers::setTimer(
			$client,
			Time::HiRes::time() + $delay,
			sub {
				my $client = shift || return;
				
				my $currentTitle = getCurrentTitle( $client, $url ) || '';
				
				return if $newTitle eq $currentTitle;

				setCurrentTitle( $url, $newTitle );

				for my $everybuddy ( $client, Slim::Player::Sync::syncedWith($client)) {
					$everybuddy->update();
				}

				# For some purposes, a change of title is a newsong...
				Slim::Control::Request::notifyFromArray( $client, [ 'playlist', 'newsong', $newTitle ] );

				$log->info("Setting title for $url to $newTitle");
			},
		);
	}
	
	return $metaTitle;
}

# If no metadata is available,
# use this to get a title, which is derived from the file path or URL.
# Also used to get human readable titles for playlist files and directories.
#
# for files, file URLs and directories:
#             Any extension is stripped off and only last part of the path
#             is returned
# for HTTP URLs:
#             URL unescaping is undone.

sub plainTitle {
	my $file = shift;
	my $type = shift;

	my $title = "";

	$log->info("Plain title for: $file");

	if (isRemoteURL($file)) {

		$title = Slim::Utils::Misc::unescape($file);

	} else {

		if (isFileURL($file)) {
			$file = Slim::Utils::Misc::pathFromFileURL($file);
			$file = Slim::Utils::Unicode::utf8decode_locale($file);
		}

		if ($file) {
			$title = (splitdir($file))[-1];
		}
		
		# directories don't get the suffixes
		if ($title && !($type && $type eq 'dir')) {
			$title =~ s/\.[^. ]+$//;
		}
	}

	if ($title) {
		$title =~ s/_/ /g;
	}
	
	$log->info(" is $title");

	return $title;
}

# get a potentially client specifically formatted title.
sub standardTitle {
	my $client    = shift;
	my $pathOrObj = shift; # item whose information will be formatted

	# Be sure to try and "readTags" - which may call into Formats::Parse for playlists.
	# XXX - exception should go here. comming soon.
	my $blessed   = blessed($pathOrObj);
	my $track     = $pathOrObj;

	if (!$blessed || !($blessed eq 'Slim::Schema::Track' || $blessed eq 'Slim::Schema::Playlist')) {

		$track = Slim::Schema->rs('Track')->objectForUrl({
			'url'      => $pathOrObj,
			'create'   => 1,
			'readTags' => 1
		});
	}

	my $fullpath = blessed($track) && $track->can('url') ? $track->url : $track;
	my $format   = undef;

	if (isPlaylistURL($fullpath) || isList($track)) {

		$format = 'TITLE';

	} else {

		$format = standardTitleFormat($client);

	}

	return displayText($client, $track, $format);
}

# format string for standard title, potentially client specific
sub standardTitleFormat {
	my $client = shift;

	if (defined($client)) {

		# in array syntax this would be
		# $titleFormat[$clientTitleFormat[$clientTitleFormatCurr]] get
		# the title format
		
		my $cprefs = $prefs->client($client);

		return $prefs->get('titleFormat')->[
			# at the array index of the client titleformat array
			$cprefs->get('titleFormat')->[
				# which is currently selected
				$cprefs->get('titleFormatCurr')
			]
		];

	} else {

		# in array syntax this would be $titleFormat[$titleFormatWeb]
		return $prefs->get('titleFormat')->[ $prefs->get('titleFormatWeb') ];
	}
}

# get display text for object by format, caches all formats for this url for this client
sub displayText {
	my $client = shift;
	my $obj    = shift;
	my $format = shift || 'TITLE';

	if (!blessed($obj) || !$obj->can('url')) {
		return '';
	}

	my $url   = $obj->url;
	my $cache = $client ? $client->musicInfoTextCache() : $musicInfoTextCache;

	if ($cache->{'url'} && $url && $cache->{'url'} eq $url) {

		if (exists $cache->{$format}) {
			return $cache->{$format};

		} elsif (Slim::Music::TitleFormatter::cacheFormat($format)) {
			return $cache->{$format} = Slim::Music::TitleFormatter::infoFormat($obj, $format);

		} else {
			return Slim::Music::TitleFormatter::infoFormat($obj, $format);
		}
	}

	my $text = Slim::Music::TitleFormatter::infoFormat($obj, $format);

	# Clear the cache first.
	$cache = {};
	$cache->{'url'}   = $url;

	if (Slim::Music::TitleFormatter::cacheFormat($format)) {
		$cache->{$format} = $text;
	}

	$client ? $client->musicInfoTextCache($cache) : $musicInfoTextCache = $cache;

	return $text;
}

#
# Guess the important tags from the filename; use the strings in preference
# 'guessFileFormats' to generate candidate regexps for matching. First
# match is accepted and applied to the argument tag hash.
#
sub guessTags {
	my $filename = shift;
	my $type = shift;
	my $taghash = shift;
	
	my $file = $filename;

	$log->info("Guessing tags for: $file");

	# Rip off from plainTitle()
	if (isRemoteURL($file)) {

		$file = Slim::Utils::Misc::unescape($file);

	} else {

		if (isFileURL($file)) {
			$file = Slim::Utils::Misc::pathFromFileURL($file);
		}

		# directories don't get the suffixes
		if ($file && !($type && $type eq 'dir')) {
			$file =~ s/\.[^.]+$//;
		}
	}

	# Replace all backslashes in the filename
	$file =~ s/\\/\//g;
	
	# Get the candidate file name formats
	my @guessformats = @{ $prefs->get('guessFileFormats') };

	# Check each format
	foreach my $guess ( @guessformats ) {
		# Create pattern from string format
		my $pat = $guess;
		
		# Escape _all_ regex special chars
		$pat =~ s/([{}[\]()^\$.|*+?\\])/\\$1/g;

		# Replace the TAG string in the candidate format string
		# with regex (\d+) for TRACKNUM, DISC, and DISCC and
		# ([^\/+) for all other tags
		$pat =~ s/(TRACKNUM|DISC{1,2})/\(\\d+\)/g;
		$pat =~ s/($Slim::Music::TitleFormatter::elemRegex)/\(\[^\\\/\]\+\)/g;

		$log->info("Using format \"$guess\" = /$pat/...");

		$pat = qr/$pat$/;

		# Check if this format matches		
		my @matches = ();

		if (@matches = $file =~ $pat) {

			$log->info("Format string $guess matched $file");

			my @tags = $guess =~ /($Slim::Music::TitleFormatter::elemRegex)/g;

			my $i = 0;

			foreach my $match (@matches) {

				$log->info("$tags[$i] => $match");

				$match =~ tr/_/ / if (defined $match);

				$match = int($match) if $tags[$i] =~ /TRACKNUM|DISC{1,2}/;
				$taghash->{$tags[$i++]} = Slim::Utils::Unicode::utf8decode_locale($match);
			}

			return;
		}
	}
	
	# Nothing found; revert to plain title
	$taghash->{'TITLE'} = plainTitle($filename, $type);	
}

sub cleanTrackNumber {
	my $tracknumber = shift;

	if (defined($tracknumber)) {

		# extracts the first digits only sequence then converts it to int
		$tracknumber =~ /(\d+)/;
		$tracknumber = $1 ? int($1) : undef;
	}
	
	return $tracknumber;
}

sub fileName {
	my $j = shift;

	if (isFileURL($j)) {

		$j = Slim::Utils::Misc::pathFromFileURL($j);

		if (defined $j && (splitdir($j))[-1]) {
			$j = (splitdir($j))[-1];
		}

	} elsif (isRemoteURL($j)) {

		$j = Slim::Utils::Misc::unescape($j);

	} else {

		$j = (splitdir($j))[-1];
	}

	return Slim::Utils::Unicode::utf8decode_locale($j);
}

sub sortFilename {
	# build the sort index
	# File sorting should look like ls -l, Windows Explorer, or Finder -
	# really, we shouldn't be doing any of this, but we'll ignore
	# punctuation, and fold the case. DON'T strip articles.
	my @nocase = map { Slim::Utils::Text::ignorePunct(Slim::Utils::Text::matchCase(fileName($_))) } @_;

	# return the input array sliced by the sorted array
	return @_[sort {$nocase[$a] cmp $nocase[$b]} 0..$#_];
}

sub isFragment {
	my $fullpath = shift;
	
	return unless isURL($fullpath);

	my $anchor = Slim::Utils::Misc::anchorFromURL($fullpath);

	if ($anchor && $anchor =~ /([\d\.]+)-([\d\.]+)/) {
		return ($1, $2);
	}
}

sub addDiscNumberToAlbumTitle {
	my ($title, $discNum, $discCount) = @_;

	# Unless the groupdiscs preference is selected:
	# Handle multi-disc sets with the same title
	# by appending a disc count to the track's album name.
	# If "disc <num>" (localized or English) is present in 
	# the title, we assume it's already unique and don't
	# add the suffix.
	# If it seems like there is only one disc in the set, 
	# avoid adding "disc 1 of 1"
	return $title unless defined $discNum and $discNum > 0;

	if (defined $discCount) {
		return $title if $discCount == 1;
		undef $discCount if $discCount < 1; # errornous count
	}

	my $discWord = string('DISC');

	return $title if $title =~ /\b((${discWord})|(Disc))\s+\d+/i;

	if (defined $discCount) {
		# add spaces to discNum to help plain text sorting
		my $discCountLen = length($discCount);
		$title .= sprintf(" (%s %${discCountLen}d %s %d)", $discWord, $discNum, string('OF'), $discCount);
	} else {
		$title .= " ($discWord $discNum)";
	}

	return $title;
}

sub splitTag {
	my $tag = shift;

	# Handle Vorbis comments where the tag can be an array.
	if (ref($tag) eq 'ARRAY') {

		return @$tag;
	}

	# Bug 774 - Splitting these genres is probably not what the user wants.
	if ($tag =~ /^\s*R\s*\&\s*B\s*$/oi || $tag =~ /^\s*Rock\s*\&\s*Roll\s*$/oi) {
		return $tag;
	}

	my @splitTags = ();
	my $splitList = $prefs->get('splitList');

	# only bother if there are some characters in the pref
	if ($splitList) {

		for my $splitOn (split(/\s+/, $splitList),'\x00') {

			my @temp = ();

			for my $item (split(/\Q$splitOn\E/, $tag)) {

				$item =~ s/^\s*//go;
				$item =~ s/\s*$//go;

				push @temp, $item if $item !~ /^\s*$/;

				if (!scalar @temp <= 1) {

					if ( $log->is_info ) {
						$log->info("Splitting $tag by $splitOn = @temp");
					}
				}
			}

			# store this for return only if there has been a successfil split
			if (scalar @temp > 1) {
				push @splitTags, @temp;
			}
		}
	}

	# return the split array, or just return the whole tag is we know there hasn't been any splitting.
	if (scalar @splitTags > 1) {

		return @splitTags;
	}

	return $tag;
}

sub isFile {
	my $url = shift;

	# We really don't need to check this every time.
	if (defined $isFile{$url}) {
		return $isFile{$url};
	}

	my $fullpath = isFileURL($url) ? Slim::Utils::Misc::pathFromFileURL($url) : $url;
	
	return 0 if (isURL($fullpath));
	
	# check against types.conf
	return 0 unless $suffixes{ lc((split /\./, $fullpath)[-1]) };

	my $stat = ((-f $fullpath && -r _) ? 1 : 0);

	if ( $log->is_debug ) {
		$log->debug(sprintf("isFile(%s) == %d", $fullpath, (1 * $stat)));
	}

	$isFile{$url} = $stat;

	return $stat;
}

sub isFileURL {
	my $url = shift;

	return (defined($url) && ($url =~ /^file:\/\//i));
}

sub isHTTPURL {
	my $url = shift;
	
	# We access MMS via HTTP, so it counts as an HTTP URL
	return 1 if isMMSURL($url);

	return (defined($url) && ($url =~ /^(http|icy):\/\//i));
}

sub isMMSURL {
	my $url = shift;

	return (defined($url) && ($url =~ /^mms:\/\//i));
}

sub isRemoteURL {
	my $url = shift || return 0;

	if ( $url =~ /^([a-zA-Z0-9\-]+):/ ) {
		my $proto = $1;
		if ( my $handler = Slim::Player::ProtocolHandlers->handlerForURL($url) ) {
			if ( $handler->can('isRemote') ) {
				return $handler->isRemote();
			}
			else {
				# Backwards-compat for 3rd party plugins not implementing isRemote
				return 1;
			}
		}
		elsif ( Slim::Player::ProtocolHandlers->isValidHandler( lc($proto) ) ) {
			# Backwards-compat for handlers without a handler class
			
			# Special case a few of our internal protocols that aren't remote
			if ( $proto =~ /^(?:db|itunesplaylist|musicmagicplaylist)$/ ) {
				return 0;
			}
			
			return 1;
		}
	}

	return 0;
}

# Only valid for the current playing song
sub canSeek {
	my ($client, $playingSong) = @_;
	my @errorString;
	my $canSeek = 0;
	
	if ( Slim::Music::Info::isRemoteURL($playingSong) ) {

		my $playingUrl;
		if (Slim::Music::Info::isPlaylist($playingSong)) {
			$log->info("Playing list $playingSong");
			my $entry = $client->remotePlaylistCurrentEntry;
			if (defined ($entry)) {
				$playingUrl = $entry->url;
			} else {
				$log->info("No current entry in remoteplaylist $playingSong ");
			}
		} else {
			$playingUrl = $playingSong;
		} ;

		# Check with protocol handler to determine if the remote stream is seekable
		my $handler = Slim::Player::ProtocolHandlers->handlerForURL($playingUrl);
		if ( $handler && $handler->can('canSeek') ) {
			$log->debug( "Checking with protocol handler $handler for canSeek" );
			if ( !$handler->canSeek( $client, $playingUrl ) ) {
				if (wantarray) {
					@errorString = $handler->can('canSeekError') 
						? $handler->canSeekError( $client, $playingUrl )
						: ('SEEK_ERROR_REMOTE');
				}
			} else {
				$canSeek = 1;
			}
		}
		else {
			@errorString = ('SEEK_ERROR_REMOTE');
		}
	} 		
	# XXX: need a better way to determine if a stream is transcoded
	# because we want to prevent seek with real transcoding but not
	# proxied streaming
	else {
		if ( $client->masterOrSelf()->audioFilehandleIsSocket() ) {
			@errorString = ('SEEK_ERROR_TRANSCODED');
		} else {
			# No seeking supported in WMA files yet
			my $track = Slim::Player::Playlist::song($client);
			if ( $track->content_type eq 'wma' ) {
				$canSeek = 0;
				@errorString = ('SEEK_ERROR_TYPE_NOT_SUPPORTED', 'WMA');
			}
			else {
				$canSeek = 1;
			}
		}	
	}
	return (wantarray ? ($canSeek, @errorString) : $canSeek);
}

sub isPlaylistURL {
	my $url = shift || return 0;
	
	# XXX: This method is pretty wrong, it says every remote URL is a playlist
	# Bug 3484, We want rhapsody tracks to display the proper title format so they can't be
	# seen as a playlist which forces only the title to be displayed.
	return if $url =~ /^rhap.+wma$/;

	if ($url =~ /^([a-zA-Z0-9\-]+):/ && Slim::Player::ProtocolHandlers->isValidHandler($1) && !isFileURL($url)) {

		return 1;
	}

	return 0;
}

sub isAudioURL { 	 
	# return true if url scheme (http: etc) defined as audio in types 	 
	my $url = shift; 	 

	if (isDigitalInput($url)) { 	 
		return 1; 	 
	} 	 

	if (isLineIn($url)) { 	 
		return 1; 	 
	} 	 

	# Let the protocol handler determine audio status 	 
	if ( my $handler = Slim::Player::ProtocolHandlers->handlerForURL( $url ) ) {
		if ( $handler && $handler->can('isAudioURL') ) { 	 
			return $handler->isAudioURL( $url ); 	 
		} 	 
	} 	 

	# alternatively check for the uri scheme being defined as type 'audio' in the suffixes hash 	 
	# this occurs if scheme: is defined in the suffix field of types.conf or a custom-types.conf, e.g.: 	 
	#  id scheme: ? audio 	 
	# it is used by plugins which know specific uri schemes to be audio, but protocol handler method is preferred 	 
	return ($url =~ /^([a-z0-9]+:)/ && defined($suffixes{$1}) && $slimTypes{$suffixes{$1}} eq 'audio'); 	 
}

sub isURL {
	my $url = shift || return 0;

	if ($url =~ /^([a-zA-Z0-9\-]+):/ && defined Slim::Player::ProtocolHandlers->isValidHandler($1)) {

		return 1;
	}

	return 0;
}

sub _isContentTypeHelper {
	my $pathOrObj = shift;
	my $type      = shift;

	if (!defined $type) {

		# XXX - exception should go here. comming soon.
		if (blessed($pathOrObj) && $pathOrObj->can('content_type')) {

			$type = $pathOrObj->content_type;

		} elsif ($pathOrObj) {

			$type = Slim::Schema->contentType($pathOrObj);
		}
	}

	return $type;
}

sub isType {
	my $pathOrObj = shift;
	my $testType  = shift;
	my $type      = shift;

	if (!$type) {
		$type = _isContentTypeHelper($pathOrObj, $type);
	}

	if ($type && ($type eq $testType)) {
		return 1;
	} else {
		return 0;
	}
}

sub isDigitalInput {
	my $pathOrObj = shift;

	return isType($pathOrObj, 'src', @_);
}

sub isLineIn {
	my $pathOrObj = shift;

	return isType($pathOrObj, 'src', @_);
}

sub isWinShortcut {
	my $pathOrObj = shift;

	return isType($pathOrObj, 'lnk', @_);
}

sub isMP3 {
	my $pathOrObj = shift;
	my $type      = shift;

	return isType($pathOrObj, 'mp3', $type) || isType($pathOrObj, 'mp2', $type);
}

sub isOgg {
	my $pathOrObj = shift;

	return isType($pathOrObj, 'ogg', @_);
}

sub isWav {
	my $pathOrObj = shift;

	return isType($pathOrObj, 'wav', @_);
}

sub isMOV {
	my $pathOrObj = shift;

	return isType($pathOrObj, 'mov', @_);
}

sub isFLAC {
	my $pathOrObj = shift;

	return isType($pathOrObj, 'flc', @_);
}

sub isAIFF {
	my $pathOrObj = shift;

	return isType($pathOrObj, 'aif', @_);
}

sub isSong {
	my $pathOrObj = shift;
	my $type      = shift;

	if (!$type) {
		$type = _isContentTypeHelper($pathOrObj, $type);
	}

	if ($type && $slimTypes{$type} && $slimTypes{$type} eq 'audio') {
		return $type;
	}
}

sub isDir {
	my $pathOrObj = shift;

	return isType($pathOrObj, 'dir', @_);
}

sub isM3U {
	my $pathOrObj = shift;

	return isType($pathOrObj, 'm3u', @_);
}

sub isPLS {
	my $pathOrObj = shift;

	return isType($pathOrObj, 'pls', @_);
}

sub isCUE {
	my $pathOrObj = shift;
	my $type      = shift;

	return isType($pathOrObj, 'cue', $type) || isType($pathOrObj, 'fec', $type);
}

sub isKnownType {
	my $pathOrObj = shift;
	my $type      = shift;

	return !isType($pathOrObj, 'unk', $type);
}

sub isList {
	my $pathOrObj = shift;
	my $type      = shift || _isContentTypeHelper($pathOrObj);

	if ($type && $slimTypes{$type} && $slimTypes{$type} =~ /list/) {
		return $type;
	}
}

sub isPlaylist {
	my $pathOrObj = shift;
	my $type      = shift || _isContentTypeHelper($pathOrObj);

	if ($type && $slimTypes{$type} && $slimTypes{$type} eq 'playlist') {
		return $type;
	}
}

sub isContainer {
	my $pathOrObj = shift;
	my $type      = shift || _isContentTypeHelper($pathOrObj);

	for my $testType (qw(cur fec)) {

		if ($type eq $testType) {
			return 1;
		}
	}

	return 0;
}

# Return a list of valid extensions for a particular type as listed in types.conf
sub validTypeExtensions {
	my $findTypes  = shift || qr/(?:list|audio)/;

	my @extensions = ();
	my $disabled   = disabledExtensions($findTypes);

	while (my ($ext, $type) = each %slimTypes) {

		next unless $type;
		next unless $type =~ /$findTypes/;

		while (my ($suffix, $value) = each %suffixes) {

			# Don't add extensions that are disabled.
			if ($disabled->{$suffix}) {
				next;
			}

			# Don't return values for 'internal' or iTunes type playlists.
			if ($ext eq $value && $suffix !~ /:/) {
				push @extensions, $suffix;
			}
		}
	}

	# Always look for Windows shortcuts - but only on Windows machines.
	# We can't parse them. Bug: 2654
	if (Slim::Utils::OSDetect::OS() eq 'win' && !$disabled->{'lnk'}) {
		push @extensions, 'lnk';
	}

	# Always look for cue sheets when looking for audio.
	if ($findTypes eq 'audio' && !$disabled->{'cue'}) {
		push @extensions, 'cue';
	}

	my $regex = join('|', @extensions);

	return qr/\.(?:$regex)$/i;
}

sub disabledExtensions {
	my $findTypes = shift || '';

	my @disabled  = ();
	my @audio     = split(/\s*,\s*/, $prefs->get('disabledextensionsaudio'));
	my @playlist  = split(/\s*,\s*/, $prefs->get('disabledextensionsplaylist'));

	if ($findTypes eq 'audio') {

		@disabled = @audio;

	} elsif ($findTypes eq 'list') {

		@disabled = @playlist;

	} else {

		@disabled = (@audio, @playlist);
	}

	return { map { $_, 1 } @disabled };
}

sub mimeType {
	my $file = shift;

	my $contentType = contentType($file);

	foreach my $mt (keys %mimeTypes) {
		if ($contentType eq $mimeTypes{$mt}) {
			return $mt;
		}
	}
	return undef;
};

sub mimeToType {
	return $mimeTypes{lc(shift)};
}

sub contentType { 
	my $url = shift;

	return Slim::Schema->contentType($url); 
}

sub typeFromSuffix {
	my $path = shift;
	my $defaultType = shift || 'unk';
	
	if (defined $path && $path =~ /\.([^.]+)$/) {
		return $suffixes{lc($1)};
	}

	return $defaultType;
}

sub typeFromPath {
	my $fullpath = shift;
	my $defaultType = shift || 'unk';

	# Remove the anchor if we're checking the suffix.
	my ($type, $anchorlessPath, $filepath);

	if ($fullpath && $fullpath !~ /\x00/) {

		# Return quickly if we have it in the cache.
		if (defined $urlToTypeCache{$fullpath}) {

			$type = $urlToTypeCache{$fullpath};
			
			return $type if $type ne 'unk';

		}
		elsif ($fullpath =~ /^([a-z]+:)/ && defined($suffixes{$1})) {

			$type = $suffixes{$1};

		} 
		elsif ( $fullpath =~ /^(?:radioio|live365)/ ) {
			# Force mp3 for protocol handlers
			return 'mp3';
		}
		else {

			$anchorlessPath = Slim::Utils::Misc::stripAnchorFromURL($fullpath);

			# strip any parameters trailing url to allow types to be inferred from url ending
			if (isRemoteURL($anchorlessPath) && $anchorlessPath =~ /(.*)\?(.*)/) {
				$anchorlessPath = $1;
			}

			$type = typeFromSuffix($anchorlessPath, $defaultType);
		}
	}

	# Process raw path, sanity check for folders
	if (isFileURL($fullpath)) {
		$filepath = Slim::Utils::Misc::pathFromFileURL($fullpath);

	} else {
		$filepath = $fullpath;
	}

	if ($filepath && -d $filepath) {
		$type = 'dir';
	}

	# We didn't get a type from above - try a little harder.
	if ((!defined($type) || $type eq 'unk') && $fullpath && $fullpath !~ /\x00/) {

		if ($filepath) {

			$anchorlessPath = Slim::Utils::Misc::stripAnchorFromURL($filepath);

			if (-f $filepath) {

				if ($filepath =~ /\.lnk$/i && Slim::Utils::OSDetect::OS() eq 'win') {

					if (Win32::Shortcut->new($filepath)) {
						$type = 'lnk';
					}

				} else {

					$type = typeFromSuffix($anchorlessPath, $defaultType);
				}

			} else {

				# file doesn't exist, go ahead and do typeFromSuffix
				$type = typeFromSuffix($anchorlessPath, $defaultType);
			}
		}
	}

	if (!defined($type) || $type eq 'unk') {
		
		$type = $defaultType;
		
		# check with the protocol handler
		if ( isRemoteURL($fullpath) ) {

			my $handler = Slim::Player::ProtocolHandlers->handlerForURL($fullpath);

			if ( $handler && $handler->can('getFormatForURL') ) {

				my $remoteType = $handler->getFormatForURL($fullpath);

				if (defined $remoteType) {

					$type = $remoteType;
				}
			}
		}	
	}

	# Don't cache remote URL types, as they may change.
	if (!isRemoteURL($fullpath)) {

		$urlToTypeCache{$fullpath} = $type;
	}

	$log->debug("$type file type for $fullpath");

	return $type;
}

sub variousArtistString {

	return ($prefs->get('variousArtistsString') || string('VARIOUSARTISTS'));
}


=head1 SEE ALSO

L<Slim::Schema>

=cut

1;

__END__
