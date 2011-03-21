package Slim::Plugin::RhapsodyDirect::RPDS;

# $Id$

# Rhapsody Direct RPDS firmware handler

use strict;

use Exporter::Lite;
use HTML::Entities qw(encode_entities);
use MIME::Base64 qw(decode_base64);
use Scalar::Util qw(blessed);

use Slim::Utils::Misc;
use Slim::Utils::Timers;

use constant SN_DEBUG => 0;

our @EXPORT = qw(rpds cancel_rpds);

my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.rhapsodydirect',
	'defaultLevel' => $ENV{RHAPSODY_DEV} ? 'DEBUG' : 'ERROR',
	'description'  => 'PLUGIN_RHAPSODY_DIRECT_MODULE_NAME',
});

# Can't use pluginData with coderefs because it's serialized
my $rpds_args = {};

sub handleError {
    return Slim::Plugin::RhapsodyDirect::Plugin::handleError(@_);
}

sub logError {
	my ( $client, $error, $arg2 ) = @_;
	
	SDI::Service::EventLog->log( 
		$client, 'rhapsody_error', $error, $arg2,
	);
}

# Send an rpds command
sub rpds {
	my ( $client, $args ) = @_;
	
	Slim::Utils::Timers::killTimers( $client, \&rpds_timeout );
	Slim::Utils::Timers::killTimers( $client, \&rpds_resend );
	
	return unless blessed($client);
	
	# Save callback info for rpds_handler
	$rpds_args->{$client} = $args;
	
	my $data = $args->{data};
	
	if ( !$data ) {
		# XXX: This should never happen...
		if ( $log->is_warn ) {
			$log->warn( $client->id . ' No RPDS data found to send, args: ' . Data::Dump::dump($args) );
		}
		bt();
		return;
	}

	$client->sendFrame( 'rpds', \$data );
	
	# Log all RPDS sends for debugging
	my $sent  = unpack('cC/a*', $data);

	if ( main::SLIM_SERVICE && SN_DEBUG ) {
		# Log full RPDS unless it's RPDS 2 (contains passwords)
		my $log = $sent;
		if ( $sent != 2 ) {
			$log = Data::Dump::dump($data);
		}
		
		SDI::Service::EventLog->log( 
			$client, 'rpds', $log,
		);
	}
	
	if ( $log->is_warn ) {
		if ( $sent != 2 ) {
			$sent = Data::Dump::dump($data);
		}
		$log->warn( $client->id . " RPDS packet sent: $sent" );
	}
	
	# RPDS 0 doesn't send a confirmation, so don't wait for it
	if ( $args->{_noresponse} ) {
		delete $rpds_args->{$client};
		return;
	}

	# Timeout in case the player is not responding
	Slim::Utils::Timers::setTimer(
		$client,
		Time::HiRes::time() + ( $args->{timeout} || 30 ), # Rhap can be slow
		\&rpds_timeout,
		$args
	);
}

sub rpds_timeout {
	my ( $client, $args ) = @_;
	
	my $sent_cmd = unpack 'c', $args->{data};
	
	if ( $log->is_warn ) {
		$log->warn( $client->id . " RPDS request timed out, command: $sent_cmd");
	}
	
	my $sent  = unpack('cC/a*', $args->{data});

	if ( main::SLIM_SERVICE && SN_DEBUG ) {
		# Log full RPDS unless it's RPDS 2 (contains passwords)
		if ( $sent != 2 ) {
			$sent = Data::Dump::dump( $args->{data} );
		}
		
		logError( $client, 'RPDS_TIMEOUT', "$sent_cmd / $sent" );
	}
	
	delete $rpds_args->{$client};
	
	my $cb = $args->{onError} || sub {};
	my $pt = $args->{passthrough} || [];
	my $string = $client->string('PLUGIN_RHAPSODY_DIRECT_RPDS_TIMEOUT');
	$cb->( $string, $client, @{$pt} );
	return;
}

sub cancel_rpds {
	my $client = shift;
	
	Slim::Utils::Timers::killTimers( $client, \&rpds_timeout );
	Slim::Utils::Timers::killTimers( $client, \&rpds_resend );
	
	delete $rpds_args->{$client};
}

sub rpds_handler {
	my ( $client, $data_ref ) = @_;
	
	if ( $log->is_warn ) {
		$log->warn( $client->id . " Got RPDS packet: " . Data::Dump::dump($data_ref) );
	}
	
	my $got_cmd = unpack 'C', $$data_ref;
	
	# Check for specific decoding error codes
	if ( $got_cmd >= 100 && $got_cmd < 200 ) {
		if ( main::SLIM_SERVICE && SN_DEBUG ) {
			logError( $client, "decoding failure: code $got_cmd" );
		}
		$log->error("Rhapsody decoding failure: code $got_cmd");
		return;
	}
	
	# Check for -5 getEA failures here, so we don't screw up any other rpds commands
	if ( $got_cmd == 251 ) {
		if ( main::SLIM_SERVICE && SN_DEBUG ) {
			logError( $client, 'RPDS_EA_FAILED' );
		}
		$log->debug('RPDS: getEA failed');
		return;
	}
	
	Slim::Utils::Timers::killTimers( $client, \&rpds_timeout );

	my $rpds     = delete $rpds_args->{$client} || {};
	my $sent_cmd = $rpds->{data} ? unpack( 'c', $rpds->{data} ) : 'N/A';
	
	# Check for errors sent by the player
	if ( $got_cmd == 255 ) {
		# SOAP Fault
		my (undef, $faultCode, $faultString ) = unpack 'cn/a*n/a*', $$data_ref;
		
		if ( $log->is_warn ) {
			$log->warn( $client->id . " Received RPDS fault: $faultCode - $faultString");
		}
		
		if ( main::SLIM_SERVICE && SN_DEBUG ) {
			logError( $client, 'RPDS_FAULT', "$sent_cmd / $faultString" );
		}
		
		# Mail missing EA errors, these need to be reported to Rhapsody
		if ( main::SLIM_SERVICE && $faultString =~ /Invalid Combination/ ) {
			SDI::Service::Control->mailError( "Rhapsody Missing EA", "$faultCode - $faultString" );
		}
		
		# If a user's session becomes invalid, the firmware will keep retrying getEA
		# and report a fault of 'Playback Session id $foo is not a valid session id'
		# and so we need to stop the player and get a new session
		if ( $faultString =~ /not a valid session id/ ) {
			
			my $error = $client->string('PLUGIN_RHAPSODY_DIRECT_INVALID_SESSION');
			
			# Track session errors so we don't get in a loop
			my $sessionErrors = $client->pluginData('sessionErrors') || 0;
			$sessionErrors++;
			
			$log->debug("Got invalid session error # $sessionErrors");
			
			if ( $sessionErrors > 1 ) {
				# On the second error, give up
				$log->debug("Giving up after multiple invalid session errors");
				
				# Stop the player
				Slim::Player::Source::playmode( $client, 'stop' );
				
				handleError( $error, $client );
				
				return;
			}
			
			$client->pluginData( sessionErrors => $sessionErrors );
			
			# Retry if command was 3 to get track info
			if ( $sent_cmd eq '3' ) {
				if ( $log->is_debug ) {
					$log->debug( $client->id, ' Getting a new session and retrying' );
				}
				retry_new_session( $client, $rpds );
				return;
			}
			
			# Stop the player
			Slim::Player::Source::playmode( $client, 'stop' );
			
			my $restart = sub {
				# Clear radio data if any, so we always get a new radio track
				$client->pluginData( radioTrack => 0 );
				
				Slim::Plugin::RhapsodyDirect::ProtocolHandler::gotTrackError(
					$error, $client
				);
			};
			
			# call endPlaybackSession and then restart playback, which
			# will get a new session
			rpds( $client, {
				data        => pack( 'c', 6 ),
				callback    => $restart,
				onError     => $restart,
				passthrough => [],
			} );
			
			return;
		}
		
		# Treat failure to get EA like a direct stream error
		if ( $faultCode =~ /NoContentFoundException/ ) {
			Slim::Plugin::RhapsodyDirect::ProtocolHandler->handleDirectError(
				$client,
				Slim::Player::Playlist::url($client),
				$faultCode,
				$faultString,
			);
			return;
		}
		
		my $cb = $rpds->{onError} || sub {};
		my $pt = $rpds->{passthrough} || [];
		my $string = sprintf( $client->string('PLUGIN_RHAPSODY_DIRECT_RPDS_FAULT'), $faultString );
		$cb->( $string, $client, @{$pt} );
		return;
	}
	elsif ( $got_cmd == 254 ) {
		# Player indicates it needs a new session
		
		# Ignore if command was 6 to end a session
		if ( $sent_cmd eq '6' ) {
			my $cb = $rpds->{onError} || sub {};
			$cb->();
			return;
		}
		
		if ( $log->is_warn ) {
			$log->warn( $client->id . " Received RPDS -2, player needs a new session");
		}
		
		if ( main::SLIM_SERVICE && SN_DEBUG ) {
			logError( $client, 'RPDS_NO_SESSION' );
		}
		
		# Get a new session and retry the previous rpds command
		retry_new_session( $client, $rpds );

		return;
	}
	elsif ( $got_cmd == 253 ) {
		# SSL connection error
		if ( $log->is_warn ) {
			$log->warn( $client->id . " Received RPDS -3, SSL connection error");
		}
		
		if ( main::SLIM_SERVICE && SN_DEBUG ) {
			logError( $client, 'RPDS_SSL_ERROR' );
		}
		
		my $cb = $rpds->{onError} || sub {};
		my $pt = $rpds->{passthrough} || [];
		my $string = $client->string('PLUGIN_RHAPSODY_DIRECT_RPDS_SSL_ERROR');
		$cb->( $string, $client, @{$pt} );
		
		return;
	}
	elsif ( $got_cmd == 252 ) {
		# Another SSL connection is still in progress, we need to wait and try
		# sending the request again
		
		if ( $log->is_warn ) {
			$log->warn( $client->id . " Received RPDS -4, SSL connection already in use, retrying later");
		}
		
		if ( main::SLIM_SERVICE && SN_DEBUG ) {
			logError( $client, 'RPDS_SSL_IN_USE' );
		}
		
		# Try to resend in a bit
		Slim::Utils::Timers::setTimer(
			$client,
			Time::HiRes::time() + 2,
			\&rpds_resend,
			undef,
			$rpds,
		);
		
		return;
	}	
	
	if ( !$rpds || $got_cmd ne $sent_cmd ) {
		if ( $log->is_warn ) {
			$log->warn( $client->id . " Ignoring unrequested or old RPDS packet (got $got_cmd, expected $sent_cmd)" );
		}
		
		if ( main::SLIM_SERVICE && SN_DEBUG ) {
			logError( $client, "RPDS_OLD: $got_cmd" );
		}
		
		return;
	}
	
	# On an rpds 2 response, we have a new session so reset sessionErrors
	if ( $got_cmd eq '2' ) {
		$log->debug("New playback session obtained, resetting sessionErrors count to 0");
		$client->pluginData( sessionErrors => 0 );
	}
	
	my $cb = $rpds->{callback};
	my $pt = $rpds->{passthrough} || [];
	
	$cb->( $client, $$data_ref, @{$pt} );
}

# Resend an RPDS request that failed due to an invalid session
sub rpds_resend {
	my ( $client, undef, $rpds ) = @_;
	
	if ( $log->is_debug ) {
		$log->debug( $client->id . ' Re-sending RPDS packet: ' . Data::Dump::dump( $rpds->{data} ) );
	}
	
	rpds( $client, {
		data        => $rpds->{data},
		callback    => $rpds->{callback},
		onError     => $rpds->{onError},
		passthrough => $rpds->{passthrough},
	} );
}

sub retry_new_session {
	my ( $client, $rpds ) = @_;
	
	my $account = $client->pluginData('account');
	
	if ( !$account ) {
		my $accountURL = Slim::Networking::SqueezeNetwork->url( '/api/rhapsody/v1/account' );

		my $http = Slim::Networking::SqueezeNetwork->new(
			\&Slim::Plugin::RhapsodyDirect::ProtocolHandler::gotAccount,
			\&Slim::Plugin::RhapsodyDirect::ProtocolHandler::gotAccountError,
			{
				client => $client,
				cb     => sub {
					# try again
					retry_new_session( $client, $rpds );
				},
				ecb    => sub {
					my $error = shift;
					$error = $client->string('PLUGIN_RHAPSODY_DIRECT_ERROR_ACCOUNT') . ": $error";
					handleError( $error, $client );
				},
			},
		);

		$log->debug("Getting Rhapsody account from SqueezeNetwork");

		$http->get( $accountURL );

		return;
	}
	
	if ( $log->is_debug ) {
		$log->debug( $client->id, ' Getting a new session and then retrying ' . Data::Dump::dump( $rpds->{data} ) );
	}
	
	# Choose the correct account to use for this player's session
	my $username = $account->{username}->[0];
	my $password = $account->{password}->[0];
	
	if ( $account->{defaults} ) {
		if ( my $default = $account->{defaults}->{ $client->id } ) {
			$log->debug( $client->id, " Using default account $default" );
			
			my $i = 0;
			for my $user ( @{ $account->{username} } ) {
				if ( $default eq $user ) {
					$username = $account->{username}->[ $i ];
					$password = $account->{password}->[ $i ];
					last;
				}
				$i++;
			}
		}
	}

	my $packet = pack 'cC/a*C/a*C/a*C/a*', 
		2,
		encode_entities( $username ),
		$account->{cobrandId}, 
		encode_entities( decode_base64( $password ) ), 
		$account->{clientType};
	
	rpds( $client, {
		data        => $packet,
		callback    => \&rpds_resend,
		onError     => \&handleError,
		passthrough => [ $rpds ],
	} );
}

1;

