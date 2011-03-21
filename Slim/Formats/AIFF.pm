package Slim::Formats::AIFF;

# $Id: AIFF.pm 29014 2009-10-26 20:19:20Z andy $
#
# Squeezebox Server Copyright 2001-2009 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License, 
# version 2.

use strict;
use base qw(Slim::Formats);

use Audio::Scan;

use Slim::Formats::MP3;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

=head1 NAME

Slim::Formats::AIFF

=head1 SYNOPSIS

my $tags = Slim::Formats::AIFF->getTag( $filename );

=head1 DESCRIPTION

Read tags embedded in AIFF files.

=head1 METHODS

=head2 getTag( $filename )

Extract and return audio information & any embedded metadata found.

=head1 SEE ALSO

L<Slim::Formats>, L<Slim::Utils::SoundCheck>

=cut

my $log = logger('formats.audio');

my $prefs = preferences('server');

sub getTag {
	my $class = shift;
	my $file  = shift || return {};

	my $s = Audio::Scan->scan($file);
	
	my $info = $s->{info};
	my $tags = $s->{tags};
	
	return unless $info->{song_length_ms};

	# Add file info
	$tags->{OFFSET}     = $info->{audio_offset};
	$tags->{SIZE}       = $info->{audio_size};
	$tags->{SECS}       = $info->{song_length_ms} / 1000;
	$tags->{RATE}       = $info->{samplerate};
	$tags->{BITRATE}    = $info->{bitrate};
	$tags->{CHANNELS}   = $info->{channels};
	$tags->{SAMPLESIZE} = $info->{bits_per_sample};
	$tags->{BLOCKALIGN} = $info->{block_align};
	$tags->{ENDIAN}     = 1;
	
	# Map ID3 tags if file has them
	if ( $info->{id3_version} ) {
		$tags->{TAGVERSION} = $info->{id3_version};
		
		Slim::Formats::MP3->doTagMapping($tags);
	}

	return $tags;
}

*getCoverArt = \&Slim::Formats::MP3::getCoverArt;

sub canSeek { 1 }

1;
