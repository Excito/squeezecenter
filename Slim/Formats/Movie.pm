package Slim::Formats::Movie;

# $Id: Movie.pm 22935 2008-08-28 15:00:49Z andy $

# SqueezeCenter Copyright 2001-2007 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License, 
# version 2.

use strict;
use base qw(Slim::Formats);

use MP4::Info;

use Slim::Utils::Log;
use Slim::Utils::SoundCheck;

my %tagMapping = (
	'WRT'       => 'COMPOSER',
	'CPIL'      => 'COMPILATION',
	'COVR'      => 'PIC',
	'ENCRYPTED' => 'DRM',
	'SONM'      => 'TITLESORT',
	'SOAR'      => 'ARTISTSORT',
	'SOAL'      => 'ALBUMSORT',
);

if ($] > 5.007) {

	MP4::Info::use_mp4_utf8(1)
}

sub getTag {
	my $class = shift;
	my $file  = shift || return {};

	my $tags = MP4::Info::get_mp4tag($file) || {};

	while (my ($old,$new) = each %tagMapping) {

		if (exists $tags->{$old}) {

			$tags->{$new} = delete $tags->{$old};
		}
	}

	$tags->{'OFFSET'} = 0;

	# bitrate is in bits per second, not kbits per second.
	$tags->{'BITRATE'} = $tags->{'BITRATE'}   * 1000 if $tags->{'BITRATE'};
	$tags->{'RATE'}    = $tags->{'FREQUENCY'} * 1000 if $tags->{'FREQUENCY'};

	# If encoding is alac, the file is lossless.
	if ($tags->{'ENCODING'} && $tags->{'ENCODING'} eq 'alac') {

		$tags->{'LOSSLESS'}     = 1;
		$tags->{'VBR_SCALE'}    = 1;
		$tags->{'CONTENT_TYPE'} = 'alc';
	}

	# Unroll the disc info.
	if ($tags->{'DISK'} && ref($tags->{'DISK'}) eq 'ARRAY') {

		($tags->{'DISC'}, $tags->{'DISCC'}) = @{$tags->{'DISK'}};
	}

	# Check for aacgain or iTunes SoundCheck data stuffed in the '----' atom.
	if ($tags->{'META'} && ref($tags->{'META'}) eq 'ARRAY') {

		for my $meta (@{$tags->{'META'}}) {

			if ($meta->{'NAME'} =~ /replaygain/i) {

				$tags->{ uc($meta->{'NAME'}) } = $meta->{'DATA'};
			}

			elsif ($meta->{'NAME'} eq 'iTunNORM') {

				$tags->{'REPLAYGAIN_TRACK_GAIN'} = Slim::Utils::SoundCheck::normStringTodB($meta->{'DATA'});
			}
			
			elsif ($meta->{'NAME'} eq 'MusicBrainz Track Id') {
				
				$tags->{'MUSICBRAINZ_ID'} = $meta->{'DATA'};
			}
			
			elsif ($meta->{'NAME'} eq 'MusicBrainz Album Artist') {
				
				$tags->{'ALBUMARTIST'} = $meta->{'DATA'};
			}
			
			elsif ($meta->{'NAME'} eq 'MusicBrainz Sortname') {
				
				$tags->{'ARTISTSORT'} = $meta->{'DATA'};
			}
		}
	}
	
	delete $tags->{'META'};

	return $tags;
}

sub getCoverArt {
	my $class = shift;
	my $file  = shift;

	my $tags = MP4::Info::get_mp4tag($file) || {};

	if (defined $tags && ref($tags) eq 'HASH') {

		return $tags->{'COVR'};
	}

	logError("Got invalid tag data back from file: [$file]");
}

1;
