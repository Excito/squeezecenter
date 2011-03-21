#!/usr/bin/perl -w

# Squeezebox Server Copyright 2001-2009 Logitech.
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
use constant SCANNER      => 1;
use constant RESIZER      => 0;
use constant TRANSCODING  => 0;
use constant PERFMON      => 0;
use constant DEBUGLOG     => ( grep { /--nodebuglog/ } @ARGV ) ? 0 : 1;
use constant INFOLOG      => ( grep { /--noinfolog/ } @ARGV ) ? 0 : 1;
use constant SB1SLIMP3SYNC=> 0;
use constant ISWINDOWS    => ( $^O =~ /^m?s?win/i ) ? 1 : 0;
use constant ISMAC        => ( $^O =~ /darwin/i ) ? 1 : 0;

# Tell PerlApp to bundle these modules
if (0) {
	require 'auto/Compress/Raw/Zlib/autosplit.ix';
}

BEGIN {
	# With EV, only use select backend
	# I have seen segfaults with poll, and epoll is not stable
	$ENV{LIBEV_FLAGS} = 1;

	# set the AnyEvent model
	$ENV{PERL_ANYEVENT_MODEL} ||= 'EV';
	
	use Slim::bootstrap;
	use Slim::Utils::OSDetect;

	Slim::bootstrap->loadModules([qw(version Time::HiRes DBI DBD::mysql HTML::Parser XML::Parser::Expat YAML::Syck)], []);
	
	require File::Basename;
	require File::Copy;
	require File::Slurp;
	require HTTP::Request;
	require JSON::XS::VersionOneAndTwo;
	require LWP::UserAgent;
	
	import JSON::XS::VersionOneAndTwo;
};

# Force XML::Simple to use XML::Parser for speed. This is done
# here so other packages don't have to worry about it. If we
# don't have XML::Parser installed, we fall back to PurePerl.
# 
# Only use XML::Simple 2.15 an above, which has support for pass-by-ref
use XML::Simple qw(2.15);

eval {
	local($^W) = 0;      # Suppress warning from Expat.pm re File::Spec::load()
	require XML::Parser; 
};

if (!$@) {
	$XML::Simple::PREFERRED_PARSER = 'XML::Parser';
}

use Getopt::Long;
use File::Path;
use File::Spec::Functions qw(:ALL);
use EV;
use AnyEvent;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Music::Import;
use Slim::Music::Info;
use Slim::Music::MusicFolderScan;
use Slim::Music::PlaylistFolderScan;
use Slim::Player::ProtocolHandlers;
use Slim::Utils::Misc;
use Slim::Utils::OSDetect;
use Slim::Utils::PluginManager;
use Slim::Utils::Progress;
use Slim::Utils::Scanner;
use Slim::Utils::Strings qw(string);

if ( INFOLOG || DEBUGLOG ) {
    require Data::Dump;
	require Slim::Utils::PerlRunTime;
}

our $VERSION     = '7.4.0';
our $REVISION    = undef;
our $BUILDDATE   = undef;

our $prefs;
our $progress;

# Remember if the main server is running or not, to avoid LWP timeout delays
my $serverDown = 0;

my $sqlHelperClass = Slim::Utils::OSDetect->getOS()->sqlHelperClass();
eval "use $sqlHelperClass";
die $@ if $@;

sub main {

	our ($rescan, $playlists, $wipe, $itunes, $musicip, $force, $cleanup, $prefsFile, $priority);
	our ($quiet, $json, $logfile, $logdir, $logconf, $debug, $help);

	our $LogTimestamp = 1;
	our $noweb = 1;

	$prefs = preferences('server');
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
		'json=s'       => \$json,
		'LogTimestamp!'=> \$LogTimestamp,
		'help'         => \$help,
	);

	if (defined $musicmagic && !defined $musicip) {
		$musicip = $musicmagic;
	}
	
	# Start a fresh scanner.log on every scan
	if ( my $file = Slim::Utils::Log->scannerLogFile() ) {
		unlink $file if -e $file;
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
	
	($REVISION, $BUILDDATE) = Slim::Utils::Misc::parseRevision();

	$log->error("Starting Squeezebox Server scanner (v$VERSION, r$REVISION, $BUILDDATE) perl $]");

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

	main::INFOLOG && $log->info("Squeezebox Server Scanner done init...\n");

	# Take the db out of autocommit mode - this makes for a much faster scan.
	Slim::Schema->storage->dbh->{'AutoCommit'} = 0;

	my $scanType = 'SETUP_STANDARDRESCAN';

	if ($wipe) {
		$scanType = 'SETUP_WIPEDB';

	} elsif ($playlists) {
		$scanType = 'SETUP_PLAYLISTRESCAN';
	}

	# Flag the database as being scanned.
	Slim::Music::Import->setIsScanning($scanType);

	if ($cleanup) {
		Slim::Music::Import->cleanupDatabase(1);
	}

	if ($wipe) {

		eval { Slim::Schema->wipeAllData; };

		if ($@) {
			logError("Failed when calling Slim::Schema->wipeAllData: [$@]");
			logError("This is a fatal error. Exiting");
			exit(-1);
		}
		
		# Clear the artwork cache, since it will contain cached items with IDs
		# that are no longer valid.  Just delete the directory because clearing the
		# cache takes too long
		$log->error('Removing artwork cache...');
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

			eval { Slim::Utils::Scanner->scanPathOrURL({ 
				'url'      => $url,
				'progress' => 1, 
			}) };
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
		eval { Slim::Music::Import->runScanPostProcessing; }; 

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

	main::INFOLOG && $log->info("Squeezebox Server OSDetect init...");

	Slim::Utils::OSDetect::init();
	Slim::Utils::OSDetect::getOS->initSearchPath();

	# initialize Squeezebox Server subsystems
	main::INFOLOG && $log->info("Squeezebox Server settings init...");

	Slim::Utils::Prefs::init();

	Slim::Utils::Prefs::makeCacheDir();	

	main::INFOLOG && $log->info("Squeezebox Server strings init...");

	Slim::Utils::Strings::init(catdir($Bin,'strings.txt'), "EN");

	main::INFOLOG && $log->info("Squeezebox Server Info init...");

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
	--json FILE    Write progress information to a JSON file.
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

sub progressJSON {
	my $data = shift;
	
	File::Slurp::write_file( $::json, to_json($data) );
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
