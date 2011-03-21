package Slim::Music::PlaylistFolderScan;

# $Id
#
# Squeezebox Server Copyright 2001-2009 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

=head1 NAME

Slim::Music::PlaylistFolderScan

=head1 DESCRIPTION

L<Slim::Music::PlaylistFolderScan>

=cut

use strict;
use base qw(Class::Data::Inheritable);

use Slim::Music::Import;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Scanner;

{

	__PACKAGE__->mk_classdata('stillScanning');
}

my $log = logger('scan.import');

my $prefs = preferences('server');

sub init {
	my $class = shift;

	Slim::Music::Import->addImporter($class, {
		'playlistOnly' => 1,
	});

	# Enable Folder scan only if playlistdir is set and is a valid directory
	my $enabled  = 0;
	my $playlistDir = $prefs->get('playlistdir');

	if (defined $playlistDir && -d $playlistDir) {

		$enabled = 1;
	}

	Slim::Music::Import->useImporter($class, $enabled);
}

sub startScan {
	my $class   = shift;
	my $dir     = shift || $prefs->get('playlistdir');
	my $recurse = shift;

	if (!defined $dir || !-d $dir) {

		main::INFOLOG && $log->info("Skipping playlist folder scan - playlistdir is undefined.");

		doneScanning();
		return;
	}

	if ($class->stillScanning) {

		main::INFOLOG && $log->info("Scan already in progress. Restarting");

		$class->stillScanning(0);
	} 

	$class->stillScanning(1);

	if (!defined $recurse) {
		$recurse = 1;
	}

	main::INFOLOG && $log->info("Starting playlist folder scan");
	
	# Bug 6710, clear all 'ssp' playlists before rescanning
	main::INFOLOG && $log->info("Clearing internal ssp playlists");
	Slim::Schema->rs('Playlist')->clearInternalPlaylists();

	Slim::Utils::Scanner->scanDirectory({
		'url'       => $dir,
		'recursive' => $recurse,
		'types'     => 'list',
		'scanName'  => 'playlist',
		'progress'  => 1,
	});

	$class->doneScanning;
}

sub doneScanning {
	my $class = shift;

	# If scan aborted, $stillScanning will already be false.
	return if !$class->stillScanning;

	main::INFOLOG && $log->info("Finished background scan of playlist folder.");

	$class->stillScanning(0);

	Slim::Music::Import->endImporter('PLAYLIST');
}

=head1 SEE ALSO

L<Slim::Music::Import>

=cut

1;

__END__
