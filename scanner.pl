#!/usr/bin/perl -w

# SqueezeCenter Copyright 2001-2007 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#

require 5.008_001;
use strict;
use warnings;

use FindBin qw($Bin);
use lib $Bin;

use constant SLIM_SERVICE => 0;

# Tell PerlApp to bundle these modules
if (0) {
	require Encode::CN;
	require Encode::JP;
	require Encode::KR;
	require Encode::TW;
}

BEGIN {
	use Slim::bootstrap;
	use Slim::Utils::OSDetect;

	Slim::bootstrap->loadModules([qw(version Time::HiRes DBD::mysql DBI HTML::Parser XML::Parser::Expat YAML::Syck)], []);
};

use Getopt::Long;
use File::Path;
use File::Spec::Functions qw(:ALL);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Music::Import;
use Slim::Music::Info;
use Slim::Music::MusicFolderScan;
use Slim::Music::PlaylistFolderScan;
use Slim::Player::ProtocolHandlers;
use Slim::Utils::Misc;
use Slim::Utils::MySQLHelper;
use Slim::Utils::OSDetect;
use Slim::Utils::PluginManager;
use Slim::Utils::Progress;
use Slim::Utils::Scanner;
use Slim::Utils::Strings qw(string);
use Slim::Control::Request;

sub main {

	our ($rescan, $playlists, $wipe, $itunes, $musicip, $force, $cleanup, $prefsFile, $progress, $priority);
	our ($quiet, $logfile, $logdir, $logconf, $debug, $help);

	our $LogTimestamp = 1;

	my $prefs = preferences('server');
	my $musicmagic;

	$prefs->readonly;

	GetOptions(
		'force'        => \$force,
		'cleanup'      => \$cleanup,
		'rescan'       => \$rescan,
		'wipe'         => \$wipe,
		'playlists'    => \$playlists,
		'itunes'       => \$itunes,
		'musicip'      => \$musicip,
		'musicmagic'   => \$musicmagic,
		'prefsfile=s'  => \$prefsFile,
		# prefsdir parsed by Slim::Utils::Prefs
		'progress'     => \$progress,
		'priority=i'   => \$priority,
		'logfile=s'    => \$logfile,
		'logdir=s'     => \$logdir,
		'logconfig=s'  => \$logconf,
		'debug=s'      => \$debug,
		'quiet'        => \$quiet,
		'LogTimestamp!'=> \$LogTimestamp,
		'help'         => \$help,
	);

	if (defined $musicmagic && !defined $musicip) {
		$musicip = $musicmagic;
	}

	Slim::Utils::Log->init({
		'logconf' => $logconf,
		'logdir'  => $logdir,
		'logfile' => $logfile,
		'logtype' => 'scanner',
		'debug'   => $debug,
	});

	if ($help || (!$rescan && !$wipe && !$playlists && !$musicip && !$itunes && !scalar @ARGV)) {
		usage();
		exit;
	}

	# Redirect STDERR to the log file.
	if (!$progress) {
		tie *STDERR, 'Slim::Utils::Log::Trapper';
	}

	STDOUT->autoflush(1);

	my $log = logger('server');

	# Bring up strings, database, etc.
	initializeFrameworks($log);

	# Set priority, command line overrides pref
	if (defined $priority) {
		Slim::Utils::Misc::setPriority($priority);
	} else {
		Slim::Utils::Misc::setPriority( $prefs->get('scannerPriority') );
	}

	if (!$force && Slim::Music::Import->stillScanning) {

		msg("Import: There appears to be an existing scanner running.\n");
		msg("Import: If this is not the case, run with --force\n");
		msg("Exiting!\n");
		exit;
	}

	if ($playlists) {

		Slim::Music::PlaylistFolderScan->init;
		Slim::Music::Import->scanPlaylistsOnly(1);

	} else {

		Slim::Music::PlaylistFolderScan->init;
		Slim::Music::MusicFolderScan->init;
	}

	# Various importers - should these be hardcoded?
	if ($itunes) {
		initClass('Slim::Plugin::iTunes::Importer');
	}

	if ($musicip) {
		initClass('Slim::Plugin::MusicMagic::Importer');
	}

	#checkDataSource();

	$log->info("SqueezeCenter done init...\n");

	# Take the db out of autocommit mode - this makes for a much faster scan.
	Slim::Schema->storage->dbh->{'AutoCommit'} = 0;

	# Flag the database as being scanned.
	Slim::Music::Import->setIsScanning(1);

	if ($cleanup) {
		Slim::Music::Import->cleanupDatabase(1);
	}

	if ($wipe) {

		eval { Slim::Schema->txn_do(sub { Slim::Schema->wipeAllData }) };

		if ($@) {
			logError("Failed when calling Slim::Schema->wipeAllData: [$@]");
			logError("This is a fatal error. Exiting");
			exit(-1);
		}
		
		# Clear the artwork cache, since it will contain cached items with IDs
		# that are no longer valid.  Just delete the directory because clearing the
		# cache takes too long
		my $artworkCacheDir = catdir( $prefs->get('cachedir'), 'Artwork' );
		eval { rmtree( $artworkCacheDir ); };
	}

	# Don't wrap the below in a transaction - we want to have the server
	# periodically update the db. This is probably better than a giant
	# commit at the end, but is debatable.
	# 
	# NB: Slim::Schema::throw_exception really isn't right now - it's just
	# printing an error and bt(). Once the server can handle & log
	# exceptions properly, it should croak(), so the exception is
	# propagated to the higher levels.
	#
	# We've been passed an explict path or URL - deal with that.
	if (scalar @ARGV) {

		for my $url (@ARGV) {

			eval { Slim::Utils::Scanner->scanPathOrURL({ 'url' => $url }) };
		}

	} else {

		# Otherwise just use our Importers to scan.
		eval {

			if ($wipe) {
				Slim::Music::Import->resetImporters;
			}

			Slim::Music::Import->runScan;
		};
	}

	if ($@) {

		logError("Failed when running main scan: [$@]");
		logError("Skipping post-process & Not updating lastRescanTime!");

	} else {

		# Run mergeVariousArtists, artwork scan, etc.
		eval { Slim::Schema->txn_do(sub { Slim::Music::Import->runScanPostProcessing }) }; 

		if ($@) {

			logError("Failed when running scan post-process: [$@]");
			logError("Not updating lastRescanTime!");

		} else {

			Slim::Music::Import->setLastScanTime;

			if ($@) {
				logError("Failed to update lastRescanTime: [$@]");
				logError("You may encounter problems next rescan!");
			}
		}
	}

	# Wipe templates if they exist.
	rmtree( catdir($prefs->get('cachedir'), 'templates') );
}

sub initializeFrameworks {
	my $log = shift;

	$log->info("SqueezeCenter OSDetect init...");

	Slim::Utils::OSDetect::init();
	Slim::Utils::OSDetect::initSearchPath();

	# initialize SqueezeCenter subsystems
	$log->info("SqueezeCenter settings init...");

	Slim::Utils::Prefs::init();

	Slim::Utils::Prefs::makeCacheDir();	

	$log->info("SqueezeCenter strings init...");

	Slim::Utils::Strings::init(catdir($Bin,'strings.txt'), "EN");

	# $log->info("SqueezeCenter MySQL init...");
	# Slim::Utils::MySQLHelper->init();

	$log->info("SqueezeCenter Info init...");

	Slim::Music::Info::init();
	
	# Bug 6721
	# The ProtocolHandlers class won't have all our handlers registered,
	# and this can cause problems scanning playlists that contain URLs
	# that use a protocol handler, i.e. rhapd://
	my @handlers = qw(
		live365
		loop
		pandora
		rhapd
		slacker
		source
	);
	
	for my $handler ( @handlers ) {
		Slim::Player::ProtocolHandlers->registerHandler( $handler => 1 );
	}
}

sub usage {
	print <<EOF;
Usage: $0 [debug options] [--rescan] [--wipe] [--itunes] [--musicip] <path or URL>

Command line options:

	--force        Force a scan, even if we think a scan is already taking place.
	--cleanup      Run a database cleanup job at the end of the scan
	--rescan       Look for new files since the last scan.
	--wipe         Wipe the DB and start from scratch
	--playlists    Only scan files in your playlistdir.
	--itunes       Run the iTunes Importer.
	--musicip      Run the MusicIP Importer.
	--progress     Show a progress bar of the scan.
	--prefsdir     Specify alternative preferences directory.
	--priority     set process priority from -20 (high) to 20 (low)
	--logfile      Send all debugging messages to the specified logfile.
	--logdir       Specify folder location for log file
	--logconfig    Specify pre-defined logging configuration file
	--debug        various debug options
	--quiet        keep silent
	
Examples:

	$0 --rescan /Users/dsully/Music

	$0 http://www.somafm.com/groovesalad.pls

EOF

}

sub initClass {
	my $class = shift;

	Slim::bootstrap::tryModuleLoad($class);

	if ($@) {
		logError("Couldn't load $class: $@");
	} else {
		$class->initPlugin;
	}
}

sub cleanup {

	# Make sure to flush anything in the database to disk.
	if ($INC{'Slim/Schema.pm'} && Slim::Schema->storage) {
		Slim::Music::Import->setIsScanning(0);

		Slim::Schema->forceCommit;
		Slim::Schema->disconnect;
	}
}

sub END {

	Slim::bootstrap::theEND();
}

sub idleStreams {}

main();

__END__
