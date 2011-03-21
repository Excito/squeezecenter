package Slim::Utils::PluginManager;

# SqueezeCenter Copyright 2001-2007 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.
#
# $Id: PluginManager.pm 24700 2009-01-17 11:17:46Z adrian $

# TODO:
#
# * Enable plugins that OP_NEEDS_ENABLE
# * Disable plugins that OP_NEEDS_DISABLE 
# 
# * Uninstall Plugins that have been marked as OP_NEEDS_UNINSTALL
#
# * Handle install of new plugins from web ui
#   - Unzip zip files to a cache dir, and read install.xml to verify
#   - Perform install of plugins marked OP_NEEDS_INSTALL
#
# * Check plugin versions from cache on new version of SqueezeCenter 
#   - Mark as OP_NEEDS_UPGRADE
# 
# * Install by id (UUID)?
# * Copy HTML/* into a common folder, so INCLUDE_PATH is shorter?
#   There's already a namespace for each plugin.

use strict;

use File::Basename qw(dirname);
use File::Spec::Functions qw(:ALL);
use File::Next;
use FindBin qw($Bin);
use Path::Class;
use XML::Simple;
use YAML::Syck;

use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::OSDetect;
use Slim::Utils::Prefs;
use Slim::Utils::Strings;
use Slim::Utils::Versions;

# XXXX - These constants will probably change. This is just a rough start.
use constant STATE_ENABLED  => 1;
use constant STATE_DISABLED => 0;

use constant OP_NONE            => "";
use constant OP_NEEDS_INSTALL   => "needs-install";
use constant OP_NEEDS_UPGRADE   => "needs-upgrade";
use constant OP_NEEDS_UNINSTALL => "needs-uninstall";
use constant OP_NEEDS_ENABLE    => "needs-enable";
use constant OP_NEEDS_DISABLE   => "needs-disable";

use constant CACHE_VERSION => 2;

my @pluginRootDirs = ();
my $plugins        = {};
my $cacheInfo      = {};

my $prefs = preferences('plugin.state');
my $log   = logger('server.plugins');

# On SN, disable some SC-only plugins
my %SKIP = ();
if ( main::SLIM_SERVICE ) {
	%SKIP = (
		'Slim::Plugin::Extensions::Plugin'     => 1,
		'Slim::Plugin::Health::Plugin'         => 1,
		'Slim::Plugin::JiveExtras::Plugin'     => 1,
		'Slim::Plugin::MusicMagic::Plugin'     => 1,
		'Slim::Plugin::MyRadio::Plugin'        => 1,
		'Slim::Plugin::PreventStandby::Plugin' => 1,
		'Slim::Plugin::RS232::Plugin'          => 1,
		'Slim::Plugin::RandomPlay::Plugin'     => 1,
		'Slim::Plugin::Rescan::Plugin'         => 1,
		'Slim::Plugin::SavePlaylist::Plugin'   => 1,
		'Slim::Plugin::SlimTris::Plugin'       => 1,
		'Slim::Plugin::Snow::Plugin'           => 1,
		'Slim::Plugin::iTunes::Plugin'         => 1,
		'Slim::Plugin::xPL::Plugin'            => 1,
	);
}

# Skip obsolete plugins, they should be deleted by installers
# but may still be left over in some cases
for (
	'Slim::Plugin::Picks::Plugin',
	'Slim::Plugin::RadioIO::Plugin',
	'Slim::Plugin::ShoutcastBrowser::Plugin',
	'Slim::Plugin::Webcasters::Plugin',
) {
	$SKIP{$_} = 1;
}

sub init {
	my $class = shift;

	my ($manifestFiles, $sum) = $class->findInstallManifests;

	my $cacheInvalid;

	if (!scalar keys %{$prefs->all}) {

		$cacheInvalid = 'plugins states are not defined';

	} elsif ( -r $class->pluginCacheFile ) {
		
		$class->loadPluginCache;

		if ($cacheInfo->{'version'} != CACHE_VERSION) {

			$cacheInvalid = 'cache version does not match';

		} elsif ($cacheInfo->{'bin'} ne $Bin) {

			$cacheInvalid = 'binary location does not match';

		} elsif ($cacheInfo->{'count'} != scalar @{$manifestFiles}) {

			$cacheInvalid = 'different number of plugins in cache';

		} elsif ($cacheInfo->{'mtimesum'} != $sum) {

			$cacheInvalid = 'manifest checksum differs';
		}

	} else {

		$cacheInvalid = 'no plugin cache';
	}

	if ($cacheInvalid) {

		$log->warn("Reparsing plugin manifests - $cacheInvalid");

		$class->readInstallManifests($manifestFiles);

	} else {

		$class->checkPluginVersions;

		$class->runPendingOperations;
	}

	$class->enablePlugins;

	$cacheInfo = {
		'version' => CACHE_VERSION,
		'bin'     => $Bin,
		'count'   => scalar @{$manifestFiles},
		'mtimesum'=> $sum,
	};

	$class->writePluginCache;
}

sub pluginCacheFile {
	my $class = shift;

	return catdir( preferences('server')->get('cachedir'), 'plugin-data.yaml' );
}

sub writePluginCache {
	my $class = shift;
	
	if ( main::SLIM_SERVICE ) {
		# Don't bother with cache, assume all plugins are OK
		return;
	}

	$log->info("Writing out plugin data file.");

	# add the cacheinfo data
	$plugins->{'__cacheinfo'} = $cacheInfo;

	YAML::Syck::DumpFile($class->pluginCacheFile, $plugins);

	delete $plugins->{'__cacheinfo'};
}

sub loadPluginCache {
	my $class = shift;
	
	if ( main::SLIM_SERVICE ) {
		# Don't bother with cache, assume all plugins are OK
		return;
	}

	$log->info("Loading plugin data file.");

	$plugins = YAML::Syck::LoadFile($class->pluginCacheFile);

	$cacheInfo = delete $plugins->{'__cacheinfo'} || { 
		'version' => -1,
	};

	if ($log->is_debug) {
		$log->debug("Cache Version: " . $cacheInfo->{'version'} . 
			" Bin: ", $cacheInfo->{'bin'} . 
			" Plugins: " . $cacheInfo->{'count'} . 
			" MTimeSum: " . $cacheInfo->{'mtimesum'} );

		for my $plugin (sort keys %{$plugins}){
			$log->debug("  $plugin");
		}
	}
}

sub findInstallManifests {
	my $class = shift;

	my $mtimesum = 0;
	my @files;

	# Only find plugins that have been installed.
	my $iter = File::Next::files({

		'file_filter' => sub {
			return 1 if /^install\.xml$/;
			return 0;
		},

	}, Slim::Utils::OSDetect::dirsFor('Plugins'));

	while ( my $file = $iter->() ) {

		$mtimesum += (stat($file))[9];
		push @files, $file;
	}

	return (\@files, $mtimesum);
}

sub readInstallManifests {
	my $class = shift;
	my $files = shift;

	$plugins = {};

	for my $file (@{$files}) {

		my ($pluginName, $installManifest) = $class->_parseInstallManifest($file);

		if (!defined $pluginName) {

			next;
		}

		if ($installManifest->{'error'} eq 'INSTALLERROR_SUCCESS') {

		}

		$plugins->{$pluginName} = $installManifest;
	}
}

sub _parseInstallManifest {
	my $class = shift;
	my $file  = shift;

	my $installManifest = eval { XMLin($file) };

	if ($@) {

		logWarning("Unable to parse XML in file [$file]: [$@]");

		return undef;
	}

	my $pluginName = $installManifest->{'module'};

	$installManifest->{'basedir'} = dirname($file);

	if (!defined $pluginName) {
		
		$installManifest->{'error'} = 'INSTALLERROR_NO_PLUGIN';

		return ($file, $installManifest);
	}

	if (!$class->checkPluginVersion($installManifest)) {

		$installManifest->{'error'} = 'INSTALLERROR_INVALID_VERSION';

		return ($pluginName, $installManifest);
	}

	# Check the OS matches
	my $osDetails    = Slim::Utils::OSDetect::details();
	my $osType       = $osDetails->{'os'};
	my $osArch       = $osDetails->{'osArch'};

	my $requireOS    = 0;
	my $matchingOS   = 0;
	my $requireArch  = 0;
	my $matchingArch = 0;
	my @platforms    = $installManifest->{'targetPlatform'} || ();

	if (ref($installManifest->{'targetPlatform'}) eq 'ARRAY') {

		@platforms = @{ $installManifest->{'targetPlatform'} };
	}

	for my $platform (@platforms) {

		$requireOS = 1;

		my ($targetOS, $targetArch) = split /-/, $platform;

		if ($osType =~ /$targetOS/i) {

			$matchingOS = 1;

			if ($targetArch) {

				$requireArch = 1;

				if ($osArch =~ /$targetArch/i) {

					$matchingArch = 1;
					last;
				}
			}
		}
	}

	if ($requireOS && (!$matchingOS || ($requireArch && !$matchingArch))) {

		$installManifest->{'error'} = 'INSTALLERROR_INCOMPATIBLE_PLATFORM';

		return ($pluginName, $installManifest);
	}


	if ($installManifest->{'icon-id'}) {

		Slim::Web::Pages->addPageLinks("icons", { $pluginName => $installManifest->{'icon-id'} });

	}

	$installManifest->{'error'} = 'INSTALLERROR_SUCCESS';

	if ($installManifest->{'defaultState'} && !defined $prefs->get($pluginName)) {

		my $state = delete $installManifest->{'defaultState'};

		if ($state eq 'disabled') {

			$prefs->set($pluginName, STATE_DISABLED);

		} else {

			$prefs->set($pluginName, STATE_ENABLED);
		}
	}

	return ($pluginName, $installManifest);
}

sub checkPluginVersions {
	my $class = shift;

	while (my ($name, $manifest) = each %{$plugins}) {

		if ($manifest->{'error'} eq 'INSTALLERROR_NO_PLUGIN') {
			# skip plugins with no module - these do not need to have a target version
			next;
		}

		if (!$class->checkPluginVersion($manifest)) {

			$plugins->{$name}->{'error'} = 'INSTALLERROR_INVALID_VERSION';
		}
	}
}

sub checkPluginVersion {
	my ($class, $manifest) = @_;

	if (!$manifest->{'targetApplication'} || ref($manifest->{'targetApplication'}) ne 'HASH') {

		return 0;
	}

	my $min = $manifest->{'targetApplication'}->{'minVersion'};
	my $max = $manifest->{'targetApplication'}->{'maxVersion'};

	# Didn't match the version? Next..
	if (!Slim::Utils::Versions->checkVersion($::VERSION, $min, $max)) {

		return 0;
	}

	return 1;
}

sub enablePlugins {
	my $class = shift;

	my @incDirs = ();
	my @loaded  = ();
	
	for my $name (sort keys %$plugins) {
		
		if ( exists $SKIP{$name} ) {
			$log->debug("Skipping plugin: $name");
			next;
		}
		
		if ( main::SLIM_SERVICE && $name =~ /^Plugins/ ) {
			# Skip 3rd party plugins on SN
			next;
		}

		my $manifest = $plugins->{$name};

		# Skip plugins with no perl module.
		next unless $manifest->{'module'};

		# Skip plugins that can't be loaded.
		if ($manifest->{'error'} ne 'INSTALLERROR_SUCCESS') {
			$log->error(sprintf("Couldn't load $name. Error: %s\n", $class->getErrorString($name)));

			next;
		}

		delete $manifest->{opType};


		if (defined $prefs->get($name) && $prefs->get($name) eq STATE_DISABLED && $manifest->{'enforce'}) {
	
			$log->debug("Enabling plugin: $name - must not be disabled");
			$prefs->set($name, STATE_ENABLED);
		}

		elsif (defined $prefs->get($name) && $prefs->get($name) eq STATE_DISABLED) {

			$log->warn("Skipping plugin: $name - disabled");

			next;
		}

		$log->info("Enabling plugin: [$name]");

		my $baseDir    = $manifest->{'basedir'};
		my $module     = $manifest->{'module'};
		my $loadModule = 0;

		# Look for a lib dir that has a PAR file or otherwise.
		if (-d catdir($baseDir, 'lib')) {

			my $dir = dir( catdir($baseDir, 'lib') );

			for my $file ($dir->children) {

				if ($file =~ /\.par$/) {

					$loadModule = 1;

					require PAR;
					PAR->import({ file => $file->stringify });

					last;
				}

				if ($file =~ /\.pm$/) {

					$loadModule = 1;
					unshift @INC, catdir($baseDir, 'lib');

					last;
				}

				if ($file =~ /.*Plugins$/ && -d $file) {
					$loadModule = 1;
					unshift @INC, catdir($baseDir, 'lib');

					last;
				}
			}
		}

		if (-f catdir($baseDir, 'Plugin.pm')) {

			$loadModule = 1;
		}

		# Pull in the module
		if ($loadModule && $module) {

			if (Slim::bootstrap::tryModuleLoad($module)) {

				logError("Couldn't load $module");

			} else {

				$prefs->set($module, STATE_ENABLED);

				push @loaded, $module;
			}
		}
		
		if ( main::SLIM_SERVICE ) {
			# no web stuff for SN
			next;
		}

		# Add any available HTML to TT's INCLUDE_PATH
		my $htmlDir = catdir($baseDir, 'HTML');

		if (-d $htmlDir) {

			$log->debug("Adding HTML directory: [$htmlDir]");

			Slim::Web::HTTP::addTemplateDirectory($htmlDir);
		}

		# Add any Bin dirs to findbin search path
		my $binDir = catdir($baseDir, 'Bin');

		if (-d $binDir) {

			$log->debug("Adding Bin directory: [$binDir]");

			Slim::Utils::Misc::addFindBinPaths( catdir($binDir, Slim::Utils::OSDetect::details()->{'binArch'}), $binDir );
		}
	}

	# Call init functions for all loaded plugins - multiple passes allows plugins to offer services to each other
	# - plugins offering service to other plugins use preinitPlugin to init themselves and postinitPlugin to start the service
	# - normal plugins use initPlugin and register with services offered by other plugins at this time

	for my $initFunction (qw(preinitPlugin initPlugin postinitPlugin)) {

		for my $module (@loaded) {

			if ($module->can($initFunction)) {

				eval { $module->$initFunction };
				
				if ($@) {

					logWarning("Couldn't call $module->$initFunction: $@");
				}
			}
		}
	}
}

sub dataForPlugin {
	my $class  = shift;
	my $plugin = shift;

	if ($plugins->{$plugin}) {

		return $plugins->{$plugin};
	}

	return undef;
}

sub allPlugins {
	my $class = shift;

	return $plugins;
}

sub installedPlugins {
	my $class = shift;

	return $class->_filterPlugins('error', 'INSTALLERROR_SUCCESS');
}

sub _filterPlugins {
	my ($class, $category, $opType) = @_;

	my @found = ();

	for my $name ( keys %{$plugins} ) {

		my $manifest = $plugins->{$name};
		
		if (defined $manifest->{$category} && $manifest->{$category} eq $opType) {

			push @found, $name;
		}
	}

	return @found;
}

sub runPendingOperations {
	my $class = shift;

	# These first two should be no-ops.
	for my $plugin ($class->getPendingOperations(OP_NEEDS_ENABLE)) {

		my $manifest = $plugins->{$plugin};
	}

	for my $plugin ($class->getPendingOperations(OP_NEEDS_DISABLE)) {

		my $manifest = $plugins->{$plugin};
	}

	# Uninstall first, then install
	for my $plugin ($class->getPendingOperations(OP_NEEDS_UPGRADE)) {

		#$class->uninstallPlugin($plugin);
		my $manifest = $plugins->{$plugin};
	}

	for my $plugin ($class->getPendingOperations(OP_NEEDS_INSTALL)) {

		my $manifest = $plugins->{$plugin};
	}

	for my $plugin ($class->getPendingOperations(OP_NEEDS_UNINSTALL)) {

		my $manifest = $plugins->{$plugin};

		if (-d $manifest->{'basedir'}) {

			$log->info("Uninstall: Removing $manifest->{'basedir'}");

			# rmtree($manifest->{'basedir'});
		}

		delete $plugins->{$plugin};
	}
}

sub getPendingOperations {
	my ($class, $opType) = @_;

	return $class->_filterPlugins('opType', $opType);
}

sub getErrorString {
	my ($class, $plugin) = @_;

	unless ($plugins->{$plugin}->{error} eq 'INSTALLERROR_SUCCESS') {

		return Slim::Utils::Strings::getString($plugins->{$plugin}->{error});
	}

	return '';
}

sub enabledPlugins {
	my $class = shift;

	my @found = ();

	for my $plugin ($class->installedPlugins) {

		if (defined $prefs->get($plugin) && $prefs->get($plugin) == STATE_ENABLED) {

			unless ($plugins->{$plugin}->{opType} && ($plugins->{$plugin}->{opType} eq OP_NEEDS_INSTALL
				|| $plugins->{$plugin}->{opType} eq OP_NEEDS_ENABLE 
				|| $plugins->{$plugin}->{opType} eq OP_NEEDS_UPGRADE)) {
					
				push @found, $plugin;
			}
		}

	}

	return @found;
}

sub isEnabled {
	my $class  = shift;
	my $plugin = shift;
	
	if ( exists $SKIP{$plugin} ) {
		# Disabled on SN
		return;
	}

	my %found  = map { $_ => 1 } $class->enabledPlugins;

	if (defined $found{$plugin}) {

		return 1;
	}

	return undef;
}

sub enablePlugin {
	my $class  = shift;
	my $plugin = shift;

	my $opType = $plugins->{$plugin}->{'opType'};

	if ($opType eq OP_NEEDS_UNINSTALL) {
		return;
	}

	if ($opType ne OP_NEEDS_ENABLE) {

		$plugins->{$plugin}->{'opType'} = OP_NEEDS_ENABLE;
		$prefs->set($plugin, STATE_ENABLED);
	}
}

sub disablePlugin {
	my $class  = shift;
	my $plugin = shift;

	if ($plugins->{$plugin}->{enforce}) {
		$log->debug("Can't disable plugin: $plugin - 'enforce' set in install.xml");
		return;
	}
	
	$log->debug("Disabling plugin $plugin");

	my $opType = $plugins->{$plugin}->{'opType'};

	if ($opType eq OP_NEEDS_UNINSTALL) {
		return;
	}

	if ($opType ne OP_NEEDS_DISABLE) {

		$plugins->{$plugin}->{'opType'} = OP_NEEDS_DISABLE;
		$prefs->set($plugin, STATE_DISABLED);
	}
}

sub shutdownPlugins {
	my $class = shift;

	$log->info("Shutting down plugins...");

	for my $plugin (sort $class->enabledPlugins) {

		$class->shutdownPlugin($plugin);
	}
}

sub shutdownPlugin {
	my $class  = shift;
	my $plugin = shift;

	if ($plugin->can('shutdownPlugin')) {

		$plugin->shutdownPlugin;
	}
}

# XXX - this should go away in favor of specifying strings.txt, convert.conf,
# etc in install.xml, and having callers ask for those files.
sub pluginRootDirs {
	my $class = shift;

	if (scalar @pluginRootDirs) {
		return @pluginRootDirs;
	}

	for my $path (Slim::Utils::OSDetect::dirsFor('Plugins')) {

		opendir(DIR, $path) || next;

		for my $plugin ( readdir(DIR) ) {

			if (-d catdir($path, $plugin) && $plugin !~ m/^\./i) {

				push @pluginRootDirs, catdir($path, $plugin);
			}
		}

		closedir(DIR);
	}

	return @pluginRootDirs;
}

1;

__END__
