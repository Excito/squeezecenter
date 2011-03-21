package Slim::Music::Artwork;

# $Id: Artwork.pm 22935 2008-08-28 15:00:49Z andy $

# SqueezeCenter Copyright 2001-2007 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

=head1 NAME

Slim::Music::Artwork

=head1 DESCRIPTION

L<Slim::Music::Artwork>

=cut

use strict;

use File::Basename qw(dirname);
use File::Slurp;
use File::Spec::Functions qw(:ALL);
use Path::Class;
use Scalar::Util qw(blessed);
use Tie::Cache::LRU;

use Slim::Formats;
use Slim::Music::Import;
use Slim::Music::Info;
use Slim::Music::TitleFormatter;
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Prefs;
use Slim::Utils::Unicode;
use Slim::Utils::OSDetect;
use Slim::Web::Graphics;

# Global caches:
my $artworkDir = '';
my $log        = logger('artwork');
my $importlog  = logger('scan.import');

my $prefs = preferences('server');

tie my %lastFile, 'Tie::Cache::LRU', 32;

# Public class methods
sub findArtwork {
	my $class = shift;
	my $track = shift;
	
	my $isDebug = $importlog->is_debug;
	
	# Initialize graphics resizing
	Slim::Web::Graphics::init();

	# Only look for track/album combos that don't already have artwork.
	my $cond = {
		'me.audio'      => 1,
		'me.timestamp'  => { '>=' => Slim::Music::Import->lastScanTime },
		'album.artwork' => { '='  => undef },
	};

	my $attr = {
		'join'     => 'album',
		'group_by' => 'album',
	};

	# If the user passed in a track (dir) object, match on that base directory.
	if (blessed($track) && $track->content_type eq 'dir') {

		$cond->{'me.url'} = { 'like' => sprintf('%s%%', $track->url) };

	} elsif (blessed($track) && $track->audio) {

		$cond->{'me.url'} = { 'like' => sprintf('%s%%', dirname($track->url)) };
	}

	# Find distinct albums to check for artwork.
	my $tracks = Slim::Schema->search('Track', $cond, $attr);

	my $progress = undef;
	my $count    = $tracks->count;

	if ($count) {
		$progress = Slim::Utils::Progress->new({ 
			'type' => 'importer', 'name' => 'artwork', 'total' => $count, 'bar' => 1
		});
	}

	while (my $track = $tracks->next) {

		if ($track->coverArtExists) {

			my $album = $track->album;

			if ( !$progress ) {
				$isDebug && $importlog->debug(sprintf("Album [%s] has artwork.", $album->name));
			}

			$album->artwork($track->id);
			$album->update;
			
			if ( $prefs->get('precacheArtwork') ) {
				# Pre-cache this artwork resized to our commonly-used sizes/formats
				# 1. user's thumb size or 100x100_p (large web artwork)
				# 2. 50x50_p (small web artwork)
				# 3. 56x56_o.jpg (Jive artwork - OAR JPG)
			
				my @dims = (50);
				push @dims, $prefs->get('thumbSize') || 100;
			
				for my $dim ( @dims ) {
					$isDebug && $importlog->debug( "Pre-caching artwork for trackid " . $track->id . " at size ${dim}x${dim}_p" );
					eval {
						Slim::Web::Graphics::processCoverArtRequest( undef, 'music/' . $track->id . "/cover_${dim}x${dim}_p" );
					};
				}
				eval {
					$isDebug && $importlog->debug( "Pre-caching artwork for trackid " . $track->id . " at size 56x56_o.jpg" );
					Slim::Web::Graphics::processCoverArtRequest( undef, 'music/' . $track->id . "/cover_56x56_o.jpg" );
				};
			}
		}

		$progress->update($track->album->name);
	}

	$progress->final($count) if $count;

	Slim::Music::Import->endImporter('findArtwork');
}

sub getImageContentAndType {
	my $class = shift;
	my $path  = shift;

	# Bug 3245 - for systems who's locale is not UTF-8 - turn our UTF-8
	# path into the current locale.
	my $locale = Slim::Utils::Unicode::currentLocale();

	if ($locale ne 'utf8' && !-e $path) {
		$path = Slim::Utils::Unicode::encode($locale, $path);
	}

	my $content = eval { read_file($path, 'binmode' => ':raw') };

	if (defined($content) && length($content)) {

		return ($content, $class->_imageContentType(\$content));
	}

	$log->is_debug && $log->debug("Image File empty or couldn't read: $path : $! [$@]");

	return undef;
}

sub readCoverArt {
	my $class = shift;
	my $track = shift;  

	my $url  = Slim::Utils::Misc::stripAnchorFromURL($track->url);
	my $file = $track->path;

	# Try to read a cover image from the tags first.
	my ($body, $contentType, $path) = $class->_readCoverArtTags($track, $file);

	# Nothing there? Look on the file system.
	if (!defined $body) {
		($body, $contentType, $path) = $class->_readCoverArtFiles($track, $file);
	}

	return ($body, $contentType, $path);
}

# Private class methods
sub _imageContentType {
	my $class = shift;
	my $body  = shift;

	use bytes;

	# iTunes sometimes puts PNG images in and says they are jpeg
	if ($$body =~ /^\x89PNG\x0d\x0a\x1a\x0a/) {

		return 'image/png';

	} elsif ($$body =~ /^GIF(\d\d)([a-z])/) {

		return 'image/gif';

	} elsif ($$body =~ /^.*?(\xff\xd8\xff)/) {

		my $header = $1;

		# See http://www.obrador.com/essentialjpeg/headerinfo.htm for
		# the JPEG header spec.
		#
		# jpeg images must start with ff d8 or they are not jpeg,
		# the next table will always start with ff as well, so look
		# for that. JFIF is an addition to the standard, we've seen
		# baseline images (bug 3850) without a JFIF header.
		# sometimes there is junk before.
		$$body =~ s/^.*?$header/$header/;

		return 'image/jpeg';

	} elsif ($$body =~ /^BM/) {

		return 'image/bmp';
	}

	return 'application/octet-stream';
}

sub _readCoverArtTags {
	my $class = shift;
	my $track = shift;
	my $file  = shift;

	my $isInfo = $log->is_info;

	$isInfo && $log->info("Looking for a cover art image in the tags of: [$file]");

	if (blessed($track) && $track->can('audio') && $track->audio) {

		my $ct          = Slim::Schema->contentType($track);
		my $formatClass = Slim::Formats->classForFormat($ct);
		my $body        = undef;

		if (Slim::Formats->loadTagFormatForType($ct) && $formatClass->can('getCoverArt')) {

			$body = $formatClass->getCoverArt($file);
		}

		if ($body) {

			my $contentType = $class->_imageContentType(\$body);
			
			$isInfo && $log->info(sprintf("Found image of length [%d] bytes with type: [$contentType]", length($body)));

			return ($body, $contentType, 1);
		}

 	} else {

		$isInfo && $log->info("Not file we can extract artwork from. Skipping.");
	}

	return undef;
}

sub _readCoverArtFiles {
	my $class = shift;
	my $track = shift;
	my $path  = shift;
	
	my $isInfo = $log->is_info;

	my @names      = qw(cover Cover thumb Thumb album Album folder Folder);
	my @ext        = qw(png jpg jpeg gif);

	my $file       = file($path);
	my $parentDir  = $file->dir;
	my $trackId    = $track->id;

	$isInfo && $log->info("Looking for image files in $parentDir");

	my %nameslist  = map { $_ => [do { my $t = $_; map { "$t.$_" } @ext }] } @names;
	
	# these seem to be in a particular order - not sure if that means anything.
	my @filestotry = map { @{$nameslist{$_}} } @names;
	my $artwork    = $prefs->get('coverArt');

	# If the user has specified a pattern to match the artwork on, we need
	# to generate that pattern. This is nasty.
	if (defined($artwork) && $artwork =~ /^%(.*?)(\..*?){0,1}$/) {

		my $suffix = $2 ? $2 : ".jpg";

		if (my $prefix = Slim::Music::TitleFormatter::infoFormat(
				Slim::Utils::Misc::fileURLFromPath($track->url), $1)) {
		
			$artwork = $prefix . $suffix;
	
			$isInfo && $log->info("Variable cover: $artwork from $1");
	
			if (Slim::Utils::OSDetect::OS() eq 'win') {
				# Remove illegal characters from filename.
				$artwork =~ s/\\|\/|\:|\*|\?|\"|<|>|\|//g;
			}
	
			my $artPath = $parentDir->file($artwork)->stringify;
	
			my ($body, $contentType) = $class->getImageContentAndType($artPath);
	
			my $artDir  = dir($prefs->get('artfolder'));
	
			if (!$body && defined $artDir) {
	
				$artPath = $artDir->file($artwork)->stringify;
	
				($body, $contentType) = $class->getImageContentAndType($artPath);
			}
	
			if ($body && $contentType) {
	
				$isInfo && $log->info("Found image file: $artPath");
	
				return ($body, $contentType, $artPath);
			}
		} else {
			
			$isInfo && $log->info("Variable cover: no match from $1");
		}

	} elsif (defined $artwork) {

		unshift @filestotry, $artwork;
	}

	if (defined $artworkDir && $artworkDir eq $parentDir) {

		if (exists $lastFile{$trackId} && $lastFile{$trackId} ne 1) {

			$isInfo && $log->info("Using existing image: $lastFile{$trackId}");

			my ($body, $contentType) = $class->getImageContentAndType($lastFile{$trackId});

			return ($body, $contentType, $lastFile{$trackId});

		} elsif (exists $lastFile{$trackId}) {

			$isInfo && $log->info("No image in $artworkDir");

			return undef;
		}

	} else {

		$artworkDir = $parentDir;
		%lastFile = ();
	}

	for my $file (@filestotry) {

		$file = $parentDir->file($file)->stringify;

		next unless -f $file;

		my ($body, $contentType) = $class->getImageContentAndType($file);

		if ($body && $contentType) {

			$isInfo && $log->info("Found image file: $file");

			$lastFile{$trackId} = $file;

			return ($body, $contentType, $file);

		} else {

			$lastFile{$trackId} = 1;
		}
	}

	return undef;
}

=head1 SEE ALSO

=cut

1;
