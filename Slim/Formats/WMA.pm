package Slim::Formats::WMA;

# $Id: WMA.pm 15258 2007-12-13 15:29:14Z mherger $

# SqueezeCenter Copyright 2001-2007 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License, 
# version 2.

use strict;
use base qw(Slim::Formats);

use Audio::WMA;

my %tagMapping = (
	'TRACKNUMBER'        => 'TRACKNUM',
	'ALBUMTITLE'         => 'ALBUM',
	'AUTHOR'             => 'ARTIST',
	'VBR'                => 'VBR_SCALE',
	'PARTOFACOMPILATION' => 'COMPILATION',
	'DESCRIPTION'        => 'COMMENT',
	'GAIN_TRACK_GAIN'    => 'REPLAYGAIN_TRACK_GAIN',
	'GAIN_TRACK_PEAK'    => 'REPLAYGAIN_TRACK_PEAK',
	'GAIN_ALBUM_GAIN'    => 'REPLAYGAIN_ALBUM_GAIN',
	'GAIN_ALBUM_PEAK'    => 'REPLAYGAIN_ALBUM_PEAK',
	'PARTOFSET'          => 'DISC',
);

{
	# WMA tags are stored as UTF-16 by default.
	if ($] > 5.007) {
		Audio::WMA->setConvertTagsToUTF8(1);
	}
}

sub getTag {
	my $class = shift;
	my $file  = shift || return {};

	# This hash will map the keys in the tag to their values.
	my $tags = {};

	my $wma  = Audio::WMA->new($file) || return $tags;

	# We can have stacked tags for multple artists.
	if ($wma->tags) {
		foreach my $key (keys %{$wma->tags}) {
			$tags->{uc $key} = $wma->tags($key);
		}
	}
	
	# Map tags onto SqueezeCenter's preferred.
	while (my ($old,$new) = each %tagMapping) {

		if (exists $tags->{$old}) {
			$tags->{$new} = $tags->{$old};
			delete $tags->{$old};
		}
	}

	# Add additional info
	$tags->{'SIZE'}	    = -s $file;
	$tags->{'SECS'}	    = $wma->info('playtime_seconds');
	$tags->{'RATE'}	    = $wma->info('sample_rate');

	# WMA bitrate is reported in bps
	$tags->{'BITRATE'}  = $wma->info('bitrate');
	
	$tags->{'DRM'}      = $wma->info('drm');

	$tags->{'CHANNELS'} = $wma->info('channels');
	$tags->{'LOSSLESS'} = $wma->info('lossless') ? 1 : 0;

	$tags->{'STEREO'} = ($tags->{'CHANNELS'} && $tags->{'CHANNELS'} == 2) ? 1 : 0;
	
	return $tags;
}

sub getCoverArt {
	my $class = shift;
	my $file  = shift || return undef;

	my $tags = $class->getTag($file);

	if (ref($tags) eq 'HASH' && defined $tags->{'PICTURE'}) {

		return $tags->{'PICTURE'}->{'DATA'};
	}

	return undef;
}

1;
