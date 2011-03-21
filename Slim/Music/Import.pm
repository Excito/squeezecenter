package Slim::Music::Import;

# Squeezebox Server Copyright 2001-2009 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

=head1 NAME

Slim::Music::Import

=head1 SYNOPSIS

	my $class = 'Slim::Plugin::iTunes::Importer';

	# Make an importer available for use.
	Slim::Music::Import->addImporter($class);

	# Turn the importer on or off
	Slim::Music::Import->useImporter($class, $prefs->get('itunes'));

	# Start a serial scan of all importers.
	Slim::Music::Import->runScan;
	Slim::Music::Import->runScanPostProcessing;

	if (Slim::Music::Import->stillScanning) {
		...
	}

=head1 DESCRIPTION

This class controls the actual running of the Importers as defined by a
caller. The process is serial, and is run via the L<scanner.pl> program.

=head1 METHODS

=cut

use strict;

use base qw(Class::Data::Inheritable);

use Config;
use File::Spec::Functions;
use FindBin qw($Bin);
use Proc::Background;
use Scalar::Util qw(blessed);

use Slim::Music::Artwork;
use Slim::Music::Info;
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::OSDetect;
use Slim::Utils::Prefs;
use Slim::Player::Client;

{
	if (main::ISWINDOWS) {
		require Win32;
	}
}

{
	my $class = __PACKAGE__;

	for my $accessor (qw(cleanupDatabase scanPlaylistsOnly useFolderImporter scanningProcess)) {

		$class->mk_classdata($accessor);
	}
}

# Total of how many file scanners are running
our %importsRunning = ();
our %Importers      = ();

my $folderScanClass = 'Slim::Music::MusicFolderScan';
my $log             = logger('scan.import');
my $prefs           = preferences('server');

my $ABORT = 0;

=head2 launchScan( \%args )

Launch the external (forked) scanning process.

\%args can include any of the arguments the scanning process can accept.

=cut

sub launchScan {
	my ($class, $args) = @_;
	
	# Don't launch the scanner unless there is something to scan
	if (!$class->countImporters()) {
		return 1;
	}

	# Pass along the prefsfile & logfile flags to the scanner.
	if (defined $::prefsfile && -r $::prefsfile) {
		$args->{"prefsfile=$::prefsfile"} = 1;
	}

	Slim::Utils::Prefs->writeAll;

	my $path = Slim::Utils::OSDetect::getOS->decodeExternalHelperPath(
		Slim::Utils::Prefs->dir
	);
	
	$args->{ "prefsdir=$path" } = 1;

	if ( my $logconfig = Slim::Utils::Log->defaultConfigFile ) {

		$args->{ "logconfig=$logconfig" } = 1;
	}

	if (defined $::logdir && -d $::logdir) {
		$args->{"logdir=$::logdir"} = 1;
	}

	# Add in the various importer flags
	# TODO: rework to only access prefs IF Importer is active
	for my $importer (qw(iTunes MusicIP)) {
		my $prefs = preferences("plugin.".lc($importer));

		# TODO: one day we'll have to fully rename MusicMagic to MusicIP...
		if (Slim::Utils::PluginManager->isEnabled("Slim::Plugin::" . ($importer eq 'MusicIP' ? 'MusicMagic' : $importer) . "::Plugin") && $prefs->get(lc($importer))) {

			$args->{lc($importer)} = 1;
		}
	}

	# Set scanner priority.  Use the current server priority unless 
	# scannerPriority has been specified.

	my $scannerPriority = $prefs->get('scannerPriority');

	unless (defined $scannerPriority && $scannerPriority ne "") {
		$scannerPriority = Slim::Utils::Misc::getPriority();
	}

	if (defined $scannerPriority && $scannerPriority ne "") {
		$args->{"priority=$scannerPriority"} = 1;
	}

	my @scanArgs = map { "--$_" } keys %{$args};

	my $command  = Slim::Utils::OSDetect::getOS->scanner();

	# Bug: 3530 - use the same version of perl we were started with.
	if ($Config{'perlpath'} && -x $Config{'perlpath'} && $command !~ /\.exe$/) {

		unshift @scanArgs, $command;
		$command  = $Config{'perlpath'};
	}
	
	# Pass debug flags to scanner
	my $debugArgs = '';
	my $scannerLogOptions = Slim::Utils::Log->getScannerLogOptions();
	 
	foreach (keys %$scannerLogOptions) {
		$debugArgs .= $_ . '=' . $scannerLogOptions->{$_} . ',';
	}
	
	if ( $main::debug ) {
		$debugArgs .= $main::debug;
	}
	
	if ( $debugArgs ) {
		$debugArgs =~ s/,$//;
		push @scanArgs, '--debug', $debugArgs;
	}
	
	$class->scanningProcess(
		Proc::Background->new($command, @scanArgs)
	);
	
	# Clear progress info so scan progress displays are blank
	$class->clearProgressInfo;

	my $scanType = 'SETUP_STANDARDRESCAN';

	if ($args->{"wipe"}) {
		$scanType = 'SETUP_WIPEDB';

	} elsif ($args->{"playlists"}) {
		$scanType = 'SETUP_PLAYLISTRESCAN';
	}

	# Update a DB flag, so the server knows we're scanning.
	$class->setIsScanning($scanType);

	# Set a timer to check on the scanning process.
	Slim::Utils::Timers::setTimer(undef, (Time::HiRes::time() + 5), \&checkScanningStatus);

	return 1;
}

=head2 abortScan()

Stop the external (forked) scanning process.

=cut

sub abortScan {
	my $class = shift || __PACKAGE__;

	if ($class->stillScanning) {

		$class->scanningProcess->die();
		
		$class->checkScanningStatus();

		if (my $p = Slim::Schema->rs('Progress')->search({ 'type' => 'importer', 'name' => 'failure' })->first) {
			$p->info('SCAN_ABORTED');
			$p->update;
		}
	}
}

=head2 checkScanningStatus( )

If we're still scanning, start a timer process to notify any subscribers of a
'rescan done' status.

=cut

sub checkScanningStatus {
	my $class = shift || __PACKAGE__;

	Slim::Utils::Timers::killTimers(undef, \&checkScanningStatus);

	# Run again if we're still scanning.
	if ($class->stillScanning) {

		Slim::Utils::Timers::setTimer(undef, (Time::HiRes::time() + 5), \&checkScanningStatus);

	} else {

		if (my $p = Slim::Schema->rs('Progress')->search({ 'type' => 'importer', 'active' => 1 })->first) {
		
			$log->warn("scanner is not running, but no progress data available - scanner crashed");
	
			$p->finish( $p->finish || time() );
			$p->active(0);
			$p->update;

			my $failure = Slim::Utils::Progress->new({
				type => 'importer', 
				name => 'failure',
			});
			
			$failure->final;
			
			# we store the failed step's token to be used in UIs
			$failure->update(uc($p->name || ''));
		}

		# Clear caches, like the vaObj, etc after scanning has been finished.
		Slim::Schema->wipeCaches;

		Slim::Control::Request::notifyFromArray(undef, [qw(rescan done)]);
	}
}

=head2 lastScanTime()

Returns the last time the user ran a scan, or 0.

=cut

sub lastScanTime {
	my $class = shift;
	my $name  = shift || 'lastRescanTime';

	# May not have a DB
	return 0 if !Slim::Schema::hasLibrary();
	
	my $last  = Slim::Schema->single('MetaInformation', { 'name' => $name });

	return blessed($last) ? $last->value : 0;
}

=head2 setLastScanTime()

Set the last scan time.

=cut

sub setLastScanTime {
	my $class = shift;
	my $name  = shift || 'lastRescanTime';
	my $value = shift || time;
	
	# May not have a DB to store this in
	return if !Slim::Schema::hasLibrary();
	
	my $last = Slim::Schema->rs('MetaInformation')->find_or_create( {
		'name' => $name
	} );

	$last->value($value);
	$last->update;
}

=head2 setIsScanning( )

Set a flag in the DB to true or false if the scanner is running.

=cut

sub setIsScanning {
	my $class = shift;
	my $value = shift;

	# May not have a DB to store this in
	return if !Slim::Schema::hasLibrary();
	
	my $autoCommit = Slim::Schema->storage->dbh->{'AutoCommit'};

	if ($autoCommit) {
		Slim::Schema->storage->dbh->{'AutoCommit'} = 0;
	}

	my $isScanning = Slim::Schema->rs('MetaInformation')->find_or_create({
		'name' => 'isScanning'
	});

	$isScanning->value($value);
	$isScanning->update;

	if ($@) {
		logError("Failed to update isScanning: [$@]");
	}

	Slim::Schema->storage->dbh->{'AutoCommit'} = $autoCommit;
}

=head2 clearProgressInfo( )

Clear importer progress info stored in the database.

=cut

sub clearProgressInfo {
	my $class = shift;
	
	# May not have a DB to store this in
	return if !Slim::Schema::hasLibrary();
	
	for my $prog (Slim::Schema->rs('Progress')->search({ 'type' => 'importer' })->all) {
		$prog->delete;
	}
}

=head2 runScan( )

Start a scan of all used importers.

This is called by the scanner.pl helper program.

=cut

sub runScan {
	my $class  = shift;

	# clear progress info in case scanner.pl is run standalone
	$class->clearProgressInfo;

	# If we are scanning a music folder, do that first - as we'll gather
	# the most information from files that way and subsequent importers
	# need to do less work.
	if ($Importers{$folderScanClass} && !$class->scanPlaylistsOnly) {

		$class->runImporter($folderScanClass);

		$class->useFolderImporter(1);
	}

	# Check Import scanners
	for my $importer (keys %Importers) {

		# Don't rescan the music folder again.
		if ($importer eq $folderScanClass) {
			next;
		}
		
		# Skip non-file scanners here (i.e. artwork)
		if ( $Importers{$importer}->{'type'} && $Importers{$importer}->{'type'} ne 'file' ) {
			next;
		} 

		# These importers all implement 'playlist only' scanning.
		# See bug: 1892
		if ($class->scanPlaylistsOnly && !$Importers{$importer}->{'playlistOnly'}) {

			$log->warn("Skipping [$importer] - it doesn't implement playlistOnly scanning!");

			next;
		}

		$class->runImporter($importer);
	}

	$class->scanPlaylistsOnly(0);

	return 1;
}

=head2 runScanPostProcessing( )

This is called by the scanner.pl helper program.

Run the post-scan processing. This includes merging Various Artists albums,
finding artwork, cleaning stale db entries, and optimizing the database.

=cut

sub runScanPostProcessing {
	my $class  = shift;

	# May not have a DB to store this in
	return 1 if !Slim::Schema::hasLibrary();
	
	# Auto-identify VA/Compilation albums
	$log->error("Starting merge of various artists albums");

	$importsRunning{'mergeVariousAlbums'} = Time::HiRes::time();

	Slim::Schema->mergeVariousArtistsAlbums;

	# Post-process artwork, so we can use title formats, and use a generic
	# image to speed up artwork loading.
	$log->error("Starting artwork scan");

	$importsRunning{'findArtwork'} = Time::HiRes::time();

	Slim::Music::Artwork->findArtwork;
	
	# Run any artwork importers
	for my $importer (keys %Importers) {		
		# Skip non-artwork scanners
		if ( !$Importers{$importer}->{'type'} || $Importers{$importer}->{'type'} ne 'artwork' ) {
			next;
		}
		
		$class->runArtworkImporter($importer);
	}
	
	# Remove and dangling references.
	if ($class->cleanupDatabase) {

		# Don't re-enter
		$class->cleanupDatabase(0);

		$importsRunning{'cleanupStaleEntries'} = Time::HiRes::time();
		
		$log->error("Starting cleanup of stale track entries");

		Slim::Schema->cleanupStaleTrackEntries;
	}
	
	# Cleanup stale year entries
	Slim::Schema::Year->cleanupStaleYears;

	# Reset
	$class->useFolderImporter(0);

	# change collation in case user changed language
	my $collationRS = Slim::Schema->single('MetaInformation', { 'name' => 'setCollation' });

	if ( blessed($collationRS) && $collationRS->value ) {
		Slim::Schema->changeCollation( $collationRS->value );

		$collationRS->value(0);
		$collationRS->update;
	}
		
	# Always run an optimization pass at the end of our scan.
	$log->error("Starting Database optimization.");

	$importsRunning{'dbOptimize'} = Time::HiRes::time();

	Slim::Schema->optimizeDB;

	$class->endImporter('dbOptimize');

	main::INFOLOG && $log->info("Finished background scanning.");

	return 1;
}

=head2 deleteImporter( $importer )

Removes a importer from the list of available importers.

=cut

sub deleteImporter {
	my ($class, $importer) = @_;

	delete $Importers{$importer};
	
	$class->_checkLibraryStatus();
}

=head2 addImporter( $importer, \%params )

Add an importer to the system. Valid params are:

=over 4

=item * use => 1 | 0

Shortcut to use / not use an importer. Same functionality as L<useImporter>.

=item * reset => \&code

Code reference to reset the state of the importer.

=item * playlistOnly => 1 | 0

True if the importer supports scanning playlists only.

=item * mixer => \&mixerFunction

Generate a mix using criteria from the client's parentParams or
modeParamStack.

=item * mixerlink => \&mixerlink

Generate an HTML link for invoking the mixer.

=back

=cut

sub addImporter {
	my ($class, $importer, $params) = @_;

	$Importers{$importer} = $params;

	main::INFOLOG && $log->info("Adding $importer Scan");
	
	$class->_checkLibraryStatus();
}

=head2 runImporter( $importer )

Calls the importer's startScan() method, and adds a start time to the list of
running importers.

=cut

sub runImporter {
	my ($class, $importer) = @_;

	if ($Importers{$importer}->{'use'}) {

		$importsRunning{$importer} = Time::HiRes::time();

		# rescan each enabled Import, or scan the newly enabled Import
		$log->error("Starting $importer scan");

		$importer->startScan;

		return 1;
	}

	return 0;
}

=head2 runArtworkImporter( $importer )

Calls the importer's startArtworkScan() method, and adds a start time to the list of
running importers.

=cut

sub runArtworkImporter {
	my ($class, $importer) = @_;

	if ($Importers{$importer}->{'use'}) {

		$importsRunning{$importer} = Time::HiRes::time();

		# rescan each enabled Import, or scan the newly enabled Import
		$log->error("Starting $importer artwork scan");
		
		$importer->startArtworkScan;

		return 1;
	}

	return 0;
}

=head2 countImporters( )

Returns a count of all added and available importers.

=cut

sub countImporters {
	my $class = shift;
	my $count = 0;

	for my $importer (keys %Importers) {
		
		if ($Importers{$importer}->{'use'}) {

			main::INFOLOG && $log->info("Found importer: $importer");

			$count++;
		}
	}

	return $count;
}

=head2 resetImporters( )

Run the 'reset' function as defined by each importer.

=cut

sub resetImporters {
	my $class = shift;

	$class->_walkImporterListForFunction('reset');
}

sub _walkImporterListForFunction {
	my $class    = shift;
	my $function = shift;

	for my $importer (keys %Importers) {

		if (defined $Importers{$importer}->{$function}) {
			&{$Importers{$importer}->{$function}};
		}
	}
}

=head2 importers( )

Return a hash reference to the list of added importers.

=cut

sub importers {
	my $class = shift;

	return \%Importers;
}

=head2 useImporter( $importer, $trueOrFalse )

Tell the server to use / not use a previously added importer.

=cut

sub useImporter {
	my ($class, $importer, $newValue) = @_;

	if (!$importer) {
		return 0;
	}

	if (defined $newValue && exists $Importers{$importer}) {

		$Importers{$importer}->{'use'} = $newValue;

		if ( $newValue ) {
			$class->_checkLibraryStatus();
		}

		return $newValue;

	} else {

		return exists $Importers{$importer} ? $Importers{$importer} : 0;
	}
}

=head2 endImporter( $importer )

Removes the given importer from the running importers list.

=cut

sub endImporter {
	my ($class, $importer) = @_;

	if (exists $importsRunning{$importer}) { 

		$log->error(sprintf("Completed %s Scan in %s seconds.",
			$importer, int(Time::HiRes::time() - $importsRunning{$importer})
		));

		delete $importsRunning{$importer};
		
		Slim::Schema->forceCommit;

		return 1;
	}

	return 0;
}

=head2 stillScanning( )

Returns scan type string token if the server is still scanning your library. False otherwise.

=cut

sub stillScanning {
	my $class = __PACKAGE__;
	
	return 0 if main::SLIM_SERVICE;
	return 0 if !Slim::Schema::hasLibrary();
	
	my $imports  = scalar keys %importsRunning;

	# Check and see if there is a flag in the database, and the process is alive.
	my $scanRS   = Slim::Schema->single('MetaInformation', { 'name' => 'isScanning' });
	my $scanning = blessed($scanRS) ? $scanRS->value : 0;

	my $running  = blessed($class->scanningProcess) && $class->scanningProcess->alive ? 1 : 0;

	if ($running && $scanning) {
		return $scanning;
	}

	return 0;
}

sub _checkLibraryStatus {
	my $class = shift;
	
	if ($class->countImporters()) {
		Slim::Schema->init() if !Slim::Schema::hasLibrary();
	} else {
		Slim::Schema->disconnect() if Slim::Schema::hasLibrary();
	}
	
	return if main::SCANNER;
	
	# Tell everyone who needs to know
	Slim::Control::Request::notifyFromArray(undef, ['library', 'changed', Slim::Schema::hasLibrary() ? 1 : 0]);
}

=head1 SEE ALSO

L<Slim::Music::MusicFolderScan>

L<Slim::Music::PlaylistFolderScan>

L<Slim::Plugin::iTunes::Importer>

L<Slim::Plugin::MusicMagic::Importer>

L<Proc::Background>

=cut

1;

__END__
