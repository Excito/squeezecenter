package Slim::Plugin::SongScanner::Plugin;
use strict;
use base qw(Slim::Plugin::Base);

# Originally written by Kevin Deane-Freeman August 2004
# Revamped and revised by Alan Young & Max Spicer, April 2008   

# Provide a new mode allowing the user to jump to an arbitrary point in the
# currently playing song.  Replaces the default fast-forward/rewind behaviour,
# but also allows fast-forwards/rewinds once the mode has been entered. 
# This plugin uses Input.Bar to provide a "scanner bar".  The user moves
# the bar left and right to select a new song position.  The new song position
# is then applied when the user presses Play or after a period of inactivity
# occurs.

# This code is derived from code with the following copyright message:
#
# SqueezeCenter Copyright (c) 2001-2007 Logitech
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

use Slim::Utils::Prefs;
use Slim::Utils::Misc;
use Slim::Utils::Timers;
use Slim::Hardware::IR;
use Slim::Player::Client;
use Slim::Utils::Strings qw (string);
use File::Spec::Functions qw(:ALL);
use Time::HiRes;

use vars qw($VERSION);
$VERSION = substr(q$Revision: 1.2 $,10);

my $modeName = 'Slim::Plugin::SongScanner::Plugin';

my $JUMP_INTERVAL            = 10;    # seconds
my $LOCAL_UPDATE_INTERVAL    = 0.400; # seconds
my $REMOTE_UPDATE_INTERVAL   = 2.000; # seconds
my $EXITMODE_INTERVAL        = 15;    # seconds

sub getDisplayName {return 'PLUGIN_SONGSCANNER'}

my $log          = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.songscanner',
	'defaultLevel' => 'WARN',
	'description'  => getDisplayName(),
});

my %modeParams = (
	'header' => 'PLUGIN_SONGSCANNER_SET'
	,'stringHeader' => 1
	,'headerValue' => sub {
			my $client = shift;
			my $val = shift;

			if (! $client->pluginData('lastUpdateTime')) {
				# No new position has been selected, set offset to track the current song position and clear the cursor
				$val = Slim::Player::Source::songTime($client);
				$client->pluginData(offset => $val);
				$client->modeParam('cursor', undef);
			} else {
				# A selection is being made - set the cursor to track the current song position
				$client->modeParam('cursor', Slim::Player::Source::songTime($client));
			}

			# Work out ffwd/rew state e.g. >> 2X 
			my $rate = Slim::Player::Source::rate($client);
			my $rateText = '';
			if ($rate < 0 || $rate > 1) {
				$rateText = ($rate < 0 ? ' <<' : ' >>') . abs($rate) . 'X:';
			} elsif (Slim::Player::Source::playmode($client) =~ /pause/) {
				$rateText = ' (' . $client->string('PAUSED') . ')';
			}
			return " $rateText ";
		}
	,'headerArgs' => 'CV'
	,'overlayRef' => sub {
			my $client = shift;
			my $val = shift;
			# For some reason we get passed a reference to val rather than val itself, unlike with headerValue 
			if (ref($val)) {
			  $val = $$val;
			}

			# Display song position e.g. 1:32
			my $pos = int($val);
			my $dur = int(Slim::Player::Source::playingSongDuration($client));
		    return sprintf("%01d:%02d / %01d:%02d", $pos / 60, $pos % 60, $dur / 60, $dur % 60);
		}
	,'overlayRefArgs' => 'CV'
	,'max' => undef
	,'increment' => undef
	,'onChange' => sub { 
			my $client = shift;
			$client->pluginData(lastUpdateTime => Time::HiRes::time());
		}
	,'onChangeArgs' => 'C'
	,'callback' => \&_scannerExitHandler
	,'handleLeaveMode' => 1
	,'trackValueChanges' => 1
	# Override defaults to allow acceleration
	,'knobFlags' => Slim::Player::Client::KNOB_NOWRAP()
);

sub _timerHandler {
	my $client = shift;
		
	# Do nothing if we're no longer in the scanner (top of stack should be Input.Bar)
	if ($client->modeStack->[-2] ne $modeName) {
		return;
	}
	
	# Exit if the playing song has changed since the scanner was started
	if ($client->pluginData('playingSong') ne Slim::Player::Playlist::url($client)) {
		Slim::Player::Source::rate($client, 1);
		Slim::Buttons::Common::popModeRight($client);
		return;
	}

	# If there's a change to be applied and sufficient time has elapsed since the last change in the scanner position, apply it 
	my $lastUpdateTime = $client->pluginData('lastUpdateTime'); 
	if ($lastUpdateTime && Time::HiRes::time() - $lastUpdateTime >= $client->pluginData('updateInterval')) {
		$client->suppressStatus('all');
		Slim::Player::Source::gototime($client, $client->pluginData('offset'), 1);
		$client->suppressStatus(undef);
		$client->pluginData(lastUpdateTime => 0);
		$client->pluginData(exitModeTime => Time::HiRes::time() + $EXITMODE_INTERVAL);
	}

	# Pop the mode if nothing has happend for EXITMODE_TIME
	if (my $exitTime = $client->pluginData('exitModeTime')) {
		if (Time::HiRes::time() > $exitTime) {
			Slim::Buttons::Common::popModeRight($client);
			return;
		}
	}

	$client->update;
	
	$client->pluginData->{'activeFfwRew'}++;
	
	Slim::Utils::Timers::setTimer($client, Time::HiRes::time()+0.1, \&_timerHandler);
}

sub _scannerExitHandler {
	my ($client,$exittype) = @_;
	$exittype = uc($exittype);

	# Input.BAR should never pass POP to a callback function
	return if $exittype eq 'POP';

	if ($exittype eq 'PLAY' || $exittype eq 'RIGHT' || $exittype eq 'LEFT' || $exittype eq 'PUSH') {
		my $playmode = Slim::Player::Source::playmode($client);
		
		$log->debug('Exiting...');

		# Cancel any fast-forward or rewind
		my $originalRate = Slim::Player::Source::rate($client);
		if ($originalRate != 1 && $originalRate != 0) {
			$log->debug("Changing rate from $originalRate to 1");
			Slim::Player::Source::rate($client, 1);
		}

		# Apply any pending change in song position
		if ($client->pluginData('lastUpdateTime')) {
			$log->debug('Applying pending update');
			Slim::Player::Source::gototime($client, $client->pluginData('offset'), 1);

			#my $lines = $client->currentSongLines();
			#$lines->{'jive'} = undef;
			#$client->showBriefly($lines, {block => 1});
		}
		if ($exittype eq 'PLAY' && $playmode =~ /pause/) {
				$log->debug('Resuming playback');
				Slim::Player::Source::playmode($client, 'resume');
		}

		# Don't exit if play was used to cancel a fast-forward/rewind 
		if ($client->pluginData('jumpToMode')
			&& ($originalRate == 1 || $client->pluginData('lastUpdateTime'))) {
			Slim::Buttons::Common::popMode($client);
			$client->pluginData(jumpToMode => 0);
		}

		$client->pluginData(lastUpdateTime => 0);
		$client->update;
	}
}


my $SCAN_RATE_MULTIPLIER = 2;
my $SCAN_RATE_MAX_MULTIPLIER = 128;

# Change ffwd/rew state (2x, 4x, -2x etc)
sub _scan {
	my ($client, $direction) = @_;

	my $playmode = Slim::Player::Source::playmode($client);
	my $url      = Slim::Player::Playlist::url($client);
	my $rate     = Slim::Player::Source::rate($client);

	$log->debug("Scan requested - requested direction : $direction, current rate : $rate");

	# Do not allow rate change on remote streams
	if ( Slim::Music::Info::isRemoteURL($url) ) {
		$log->debug('Not allowing scan for remote stream');
		return;
	}

	# If a change in direction is requested, go straight to the slowest scan for that direction
	if ($direction > 0 && $rate < 0) {
		$rate = 1;
	} elsif ($direction < 0 && $rate > 0) {
		$rate = -1;
	}

	$rate *= $SCAN_RATE_MULTIPLIER;

	if (abs($rate) > $SCAN_RATE_MAX_MULTIPLIER) {
		$log->debug('Max scan rate reached');
		$client->showBriefly(
			{line => [ $client->string($direction > 0 ? 'PLUGIN_SONGSCANNER_MAX_RATE_FWD' : 'PLUGIN_SONGSCANNER_MAX_RATE_REW'), '' ],
				'jive' => undef},
			{duration => 1.5, scroll => 1}
		);
		return;
	}

	$log->debug("Setting scan rate to $rate");
	Slim::Player::Source::rate($client, $rate);
	
	if ($playmode =~ /pause/) {
		$log->debug('Resuming playback');
		Slim::Player::Source::playmode($client, 'resume');
	}
	
	# Abandon any pending scanner changes
	$client->pluginData(lastUpdateTime => 0);
	$client->update();
}

sub _jump {
	my $client = shift;
	my $interval = shift;
	
	my $offset = $client->pluginData('offset');
	
	if ($interval > 0 && $offset + (2 * $interval) < $client->modeParam('max')) {
		$client->pluginData(offset => $offset + $interval);
	} elsif ($interval < 0) {
		$client->pluginData(offset => $offset > -$interval ? $offset + $interval : 0);
	} else {
		return;
	}
	$client->pluginData(lastUpdateTime => Time::HiRes::time());
	$client->update;
}

my %functions = (
	'right' => sub  {
		my $client = shift;
		_scannerExitHandler($client,'RIGHT');
	},
	'left' => sub {
		my $client = shift;
		_scannerExitHandler($client,'LEFT');
	},
	'play' => sub {
		my $client = shift;
		_scannerExitHandler($client,'PLAY');
	},
	'pause' => sub {
		my $client = shift;
		my $playmode = Slim::Player::Source::playmode($client);
		my $rate = Slim::Player::Source::rate($client);
		# Apply any pending update 
		if ($client->pluginData('lastUpdateTime')) {
			Slim::Player::Source::gototime($client, $client->pluginData('offset'), 1);
			$client->pluginData(lastUpdateTime => 0);
		}
		if ($playmode =~ /pause/) {
			Slim::Player::Source::playmode($client, 'resume');
		} else {
			# Cancel any ffwd/rew (it's confusing to come out of pause and find ffwd/rew still active)
			if ($rate != 1 && $rate != 0) {
				Slim::Player::Source::rate($client, 1);
			}
			Slim::Player::Source::playmode($client, 'pause');
		}
		$client->update;
	},
	'jump_fwd' => sub {
		my $client = shift;
		_jump($client, $JUMP_INTERVAL);
#		_scan($client, 1);
	},
	'jump_rew' => sub {
		my $client = shift;
		_jump($client, -$JUMP_INTERVAL);
#		_scan($client, -1);
	},
	'song_scanner_fwd' => sub {
		my $client = shift;
		Slim::Buttons::Input::Bar::changePos($client, 1, 'up') if $client->pluginData('activeFfwRew') > 1;
	},
	'song_scanner_rew' => sub {
		my $client = shift;
		Slim::Buttons::Input::Bar::changePos($client, -1, 'down') if $client->pluginData('activeFfwRew') > 1; 
	},
);

sub _jumptoscanner {
	my $client = shift;
	Slim::Buttons::Common::pushModeLeft($client, $modeName);
	$client->pluginData(jumpToMode => 1);
}

sub getFunctions {
	return \%functions;
}

sub lines {
	my $line1 = string('PLUGIN_SONGSCANNER');
	my $line2 = '';
	
	return {'line'    => [$line1, $line2],}
}

sub setScanMode {
	my $client = shift;
	my $method = shift;

	if ($method eq 'pop') {
		Slim::Buttons::Common::popModeRight($client);
		return;
	}
	
	my @errorString;
	my $duration;

	my $playingSong = Slim::Player::Playlist::url($client);

	# The currently selected position in the scanner bar
	$client->pluginData(offset => 0);
	# The time (seconds since epoch) at which the user last moved the scanner bar
	$client->pluginData(lastUpdateTime => 0);
	# The number of seconds since the scanner mode was entered 
	$client->pluginData(activeFfwRew => 0);
	# Whether the scanner was entered directly (e.g. by mapped button press) or via the Extras menu
	$client->pluginData(jumpToMode => 0);
	# URL of the playing song when the scanner was started
	$client->pluginData(playingSong => $playingSong);
	# How quickly to apply updates
	$client->pluginData(updateInterval => 
		Slim::Music::Info::isRemoteURL($playingSong) ? $REMOTE_UPDATE_INTERVAL : $LOCAL_UPDATE_INTERVAL);

	if ( $playingSong ) {
		$duration = Slim::Player::Source::playingSongDuration($client);
		
		if ( !$duration ) {
			# Try to get duration from the track object
			$duration = Slim::Music::Info::getDuration($playingSong);
			if ( !$duration && Slim::Music::Info::isPlaylist($playingSong) ) {
				if ( my $entry = $client->remotePlaylistCurrentEntry ) {
					$duration = Slim::Music::Info::getDuration($entry->url);
				}
			}	
		}
		
		if ( !$duration ) {
			@errorString = ('PLUGIN_SONGSCANNER_ERR_UNKNOWNSIZE');
		}
		else {
			(undef, @errorString) = Slim::Music::Info::canSeek($client, $playingSong);
		}
	} else {
		@errorString = ('PLUGIN_SONGSCANNER_ERR_NOTRACK');
	}
	
	if ( @errorString ) {
		$client->modeParam('handledTransition',1);
		$client->showBriefly(
			{line => [ $client->string(@errorString), ''], 'jive' => undef},
			{duration => 1.5, scroll => 1,
				callback => sub {Slim::Buttons::Common::popMode($client);}
			}
		);
		# Make sure the jumpToMode flag isn't left over for next the mode is entered
		$client->pluginData( jumpToMode => 0 );
		return;		
	}
	$client->update;
	my %params = %modeParams;

	$params{'valueRef'} = \$client->pluginData->{'offset'};

	$params{'max'} = $duration;
	
	my $increment = $duration / 100;
	if ($increment < 1) {$increment = 1;} elsif ($increment > 5) {$increment = 5;}
	$params{'increment'} = $increment;

	$client->pluginData(offset => Slim::Player::Source::songTime($client));
	$client->pluginData(exitModeTime => 0);
	
	Slim::Buttons::Common::pushMode($client,'INPUT.Bar',\%params);
	
	$client->update();
	
	Slim::Utils::Timers::setTimer($client, Time::HiRes::time()+1, \&_timerHandler);
}

# Set up scanner to be called by default on fwd.hold and rew.hold from all modes
sub initPlugin {
	my $class = shift;

	# Holding fwd and rew moves the scanner bar left/right
	Slim::Hardware::IR::addModeDefaultMapping($modeName,
		{'fwd.repeat' => 'song_scanner_fwd', 'rew.repeat' => 'song_scanner_rew',
		'fwd.hold' => 'dead', 'rew.hold' => 'dead'}, 1);

	Slim::Buttons::Common::setFunction('song_scanner', \&_jumptoscanner);
	Slim::Buttons::Common::addMode($modeName, $class->getFunctions, \&setScanMode);

	$class->SUPER::initPlugin();
}
