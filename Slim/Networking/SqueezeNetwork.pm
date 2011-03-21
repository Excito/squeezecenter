package Slim::Networking::SqueezeNetwork;

# $Id: SqueezeNetwork.pm 11768 2007-04-16 18:14:55Z andy $

# Async interface to mysqueezebox.com API

use strict;
use base qw(Slim::Networking::SimpleAsyncHTTP);

use Digest::SHA1 qw(sha1_base64);
use JSON::XS::VersionOneAndTwo;
use MIME::Base64 qw(encode_base64);
use URI::Escape qw(uri_escape);

if ( !main::SLIM_SERVICE && !main::SCANNER ) {
	# init() is never called on SN so these aren't used
	require Slim::Networking::SqueezeNetwork::Players;
	require Slim::Networking::SqueezeNetwork::PrefSync;
	require Slim::Networking::SqueezeNetwork::Stats;
}

use Slim::Utils::IPDetect;
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;

my $log   = logger('network.squeezenetwork');

my $prefs = preferences('server');

# This is a hashref of mysqueezebox.com server types
#   and names.

my $_Servers = {
	sn      => 'www.mysqueezebox.com',
	update  => 'update.mysqueezebox.com',
	test    => 'www.test.mysqueezebox.com',
};

# Used only on SN
my $internal_http_host;
my $_sn_hosts;
my $_sn_hosts_re;

if ( main::SLIM_SERVICE ) {
	$internal_http_host = SDI::Util::SNConfig::get_config_value('internal_http_host');
	
	my $sn_server = __PACKAGE__->get_server('sn');
	
	my $mysb_host = SDI::Util::SNConfig::get_config_value('use_test_sn')
		? 'www.test.mysqueezebox.com'
		: 'www.mysqueezebox.com';
	my $sn_host = SDI::Util::SNConfig::get_config_value('use_test_sn')
		? 'www.test.squeezenetwork.com'
		: 'www.squeezenetwork.com';
	
	$_sn_hosts = join(q{|},
	        map { qr/\Q$_\E/ } (
			$sn_server,
			$mysb_host,
			$sn_host,
			$internal_http_host,
			($ENV{SN_DEV} ? '127.0.0.1' : ())
		)
	);
	$_sn_hosts_re = qr{
		^http://
		(?:$_sn_hosts)  # literally: (?:\Qsome.host\E|\Qother.host\E)
		(?::\d+)?	# optional port specification
		(?:/|$)		# /|$ prevents matching www.squeezenetwork.com.foo.com,
	}x;
}

sub get_server {
	my ($class, $stype) = @_;
	
	# Use SN test server if hidden test pref is set
	if ( $stype eq 'sn' && $prefs->get('use_sn_test') ) {
		$stype = 'test';
	}

	return $_Servers->{$stype}
		|| die "No hostname known for server type '$stype'";
}

# Initialize by logging into SN server time and storing our time difference
sub init {
	my $class = shift;
	
	main::INFOLOG && $log->info('SqueezeNetwork Init');
	
	# Convert old non-hashed password
	if ( my $password = $prefs->get('sn_password') ) {
		$password = sha1_base64( $password );
		$prefs->set( sn_password_sha => $password );
		$prefs->remove('sn_password');
			
		main::DEBUGLOG && $log->debug('Converted SN password to hashed version');
	}
	
	Slim::Utils::Timers::setTimer(
		undef,
		time(),
		sub {
			if ( $prefs->get('sn_email') && $prefs->get('sn_password_sha') ) {
				# Login to SN
				$class->login(
					cb  => \&_init_done,
					ecb => \&_init_error,
				);
			}
		},
	);
}

sub _init_done {
	my ( $http, $json ) = @_;
	
	my $snTime = $json->{time};
	
	if ( $snTime !~ /^\d+$/ ) {
		$http->error( "Invalid mysqueezebox.com server timestamp" );
		return _init_error( $http );
	}
	
	my $diff = $snTime - time();
	
	main::INFOLOG && $log->info("Got SqueezeNetwork server time: $snTime, diff: $diff");
	
	$prefs->set( sn_timediff => $diff );
	
	# Clear error counter
	$prefs->remove( 'snInitErrors' );
	
	# Store disabled plugins, if any
	if ( $json->{disabled_plugins} ) {
		if ( ref $json->{disabled_plugins} eq 'ARRAY' ) {
			$prefs->set( sn_disabled_plugins => $json->{disabled_plugins} );
			
			# Remove disabled plugins from player UI and web UI
			for my $plugin ( @{ $json->{disabled_plugins} } ) {
				my $pclass = "Slim::Plugin::${plugin}::Plugin";
				if ( $pclass->can('setMode') && $pclass->playerMenu) {
					Slim::Buttons::Home::delSubMenu( $pclass->playerMenu, $pclass->getDisplayName );
					main::DEBUGLOG && $log->debug( "Removing $plugin from player UI, service not allowed in country" );
				}
				
				if ( $pclass->can('webPages') && $pclass->can('menu') ) {
					Slim::Web::Pages->delPageLinks( $pclass->menu, $pclass->getDisplayName );
					main::DEBUGLOG && $log->debug( "Removing $plugin from web UI, service not allowed in country" );
				}
			}
		}
		
		$prefs->set( sn_disabled_plugins => $json->{disabled_plugins} || [] );
	}
	
	# Init the Internet Radio menu
	if ( $json->{radio_menu} ) {
		if ( Slim::Utils::PluginManager->isEnabled('Slim::Plugin::InternetRadio::Plugin') ) {
			Slim::Plugin::InternetRadio::Plugin->buildMenus( $json->{radio_menu} );
		}
	}
	
	# Init pref syncing
	Slim::Networking::SqueezeNetwork::PrefSync->init() if $prefs->get('sn_sync');
	
	# Init polling for list of SN-connected players
	Slim::Networking::SqueezeNetwork::Players->init();
	
	# Init stats
	Slim::Networking::SqueezeNetwork::Stats->init( $json );
}

sub _init_error {
	my $http  = shift;
	my $error = $http->error;
	
	$log->error( "Unable to login to mysqueezebox.com, sync is disabled: $error" );
	
	$prefs->remove('sn_timediff');
	
	# back off if we keep getting errors
	my $count = $prefs->get('snInitErrors') || 0;
	$prefs->set( snInitErrors => $count + 1 );
	
	my $retry = 300 * ( $count + 1 );
	
	$log->error( "mysqueezebox.com sync init failed: $error, will retry in $retry" );
	
	Slim::Utils::Timers::setTimer(
		undef,
		time() + $retry,
		sub { 
			__PACKAGE__->init();
		}
	);
}

# Stop all communication with SN, if the user removed their login info for example
sub shutdown {
	my $class = shift;
	
	$prefs->remove('sn_timediff');
	
	# Remove SN session
	$prefs->remove('sn_session');
	
	# Shutdown pref syncing
	Slim::Networking::SqueezeNetwork::PrefSync->shutdown();
	
	# Shutdown player list fetch
	Slim::Networking::SqueezeNetwork::Players->shutdown();
	
	# Shutdown stats
	Slim::Networking::SqueezeNetwork::Stats->shutdown();
}

# Return a correct URL for mysqueezebox.com
sub url {
	my ( $class, $path, $external ) = @_;
	
	# There are 3 scenarios:
	# 1. Local dev, running SN on localhost:3000
	# 2. An SN instance, needs to access using an internal IP
	# 3. Public user
	my $base;
	
	$path ||= '';
	
	if ( !$external ) {
		if ( main::SLIM_SERVICE ) {
			$base = 'http://' . $internal_http_host;
        }
        elsif ( $ENV{SN_DEV} ) {
			$base = 'http://127.0.0.1:3000';  # Local dev
		}
	}
	
	$base ||= 'http://' . $class->get_server('sn');
	
	return $base . $path;
}

# Is a URL on SN?
sub isSNURL {
	my ( $class, $url ) = @_;
	
	if ( main::SLIM_SERVICE ) {
		return $url =~ /$_sn_hosts_re/o;
	}
	
	my $snBase = $class->url();
	
	# Allow old SN hostname to be seen as SN
	my $oldBase = $snBase;
	$oldBase =~ s/mysqueezebox/squeezenetwork/;
	
	return $url =~ /^$snBase/ || $url =~ /^$oldBase/;
}

# Login to SN and obtain a session ID
sub login {
	my ( $class, %params ) = @_;
	
	$class = ref $class || $class;
	
	my $client = $params{client};
	
	my $username = $params{username};
	my $password = $params{password};
	
	if ( !$username || !$password ) {
		$username = $prefs->get('sn_email');
		$password = $prefs->get('sn_password_sha');
	}
	
	# Return if we don't have any SN login information
	if ( !$username || !$password ) {
		my $error = $client 
			? $client->string('SQUEEZENETWORK_NO_LOGIN')
			: Slim::Utils::Strings::string('SQUEEZENETWORK_NO_LOGIN');
			
		main::INFOLOG && $log->info( $error );
		return $params{ecb}->( undef, $error );
	}
	
	main::INFOLOG && $log->is_info && $log->info("Logging in to " . $_Servers->{sn} . " as $username");
	
	my $self = $class->new(
		\&_login_done,
		\&_error,
		{
			params  => \%params,
			Timeout => 30,
		},
	);
		
	my $time = time();
	
	my $url = $self->_construct_url(
		'login',
		{
			v => 'sc' . $::VERSION,
			u => $username,
			t => $time,
			a => sha1_base64( $password . $time ),
		},
	);
	
	$self->get( $url );
}

sub getHeaders {
	my ( $self, $client ) = @_;
	
	my @headers;
	
	# Add player ID data
	if ( $client ) {
		push @headers, 'X-Player-MAC', $client->master()->id;
		if ( my $uuid = $client->master()->uuid ) {
			push @headers, 'X-Player-UUID', $uuid;
		}
		
		# Add device id/firmware info
		if ( $client->deviceid ) {
			push @headers, 'X-Player-DeviceInfo', $client->deviceid . ':' . $client->revision;
		}
		
		# Add player name
		my $name = $client->name;
		utf8::encode($name);
		push @headers, 'X-Player-Name', encode_base64( $name, '' );
		
		push @headers, 'X-Player-Model', $client->model;
		
		# Bug 13963, Add "controlled by" string so SN knows what kind of menu to return
		if ( my $controller = $client->controlledBy ) {
			push @headers, 'X-Controlled-By', $controller;
		}
		
		# Request JSON instead of XML, it is much faster to parse
		push @headers, 'Accept', 'text/x-json, text/xml';
		
		if ( main::SLIM_SERVICE ) {
			# Indicate player is on SN and provide real client IP
			push @headers, 'X-Player-SN', 1;
			push @headers, 'X-Player-IP', $client->ip;
		}
	}
	
	return @headers;
}

sub getCookie {
	my ( $self, $client ) = @_;
	
	# Add session cookie if we have it
	if ( main::SLIM_SERVICE ) {
		# Get sid directly if running on SN
		if ( $client ) {
			my $user = $client->playerData->userid;
			my $sid  = $user->id . ':' . $user->password;
			return 'sdi_squeezenetwork_session=' . uri_escape($sid);
		}
		else {
			bt();
			$log->error( "SN request without a client" );
		}
	}
	elsif ( my $sid = $prefs->get('sn_session') ) {
		return 'sdi_squeezenetwork_session=' . uri_escape($sid);
	}
	
	return;
}

# Override to add session cookie header
sub _createHTTPRequest {
	my ( $self, $type, $url, @args ) = @_;
	
	# Add SN-specific headers
	unshift @args, $self->getHeaders( $self->params('client') );
	
	my $cookie;
	if ( $cookie = $self->getCookie( $self->params('client') ) ) {
		unshift @args, 'Cookie', $cookie;
	}
	
	if ( !$cookie && $url !~ m{api/v1/(login|radio)|public|update} ) {
		main::INFOLOG && $log->info("Logging in to SqueezeNetwork to obtain session ID");
	
		# Login and get a session ID
		$self->login(
			client => $self->params('client'),
			cb     => sub {
				if ( my $cookie = $self->getCookie( $self->params('client') ) ) {
					unshift @args, 'Cookie', $cookie;
		
					main::INFOLOG && $log->info('Got SqueezeNetwork session ID');
				}
		
				$self->SUPER::_createHTTPRequest( $type, $url, @args );
			},
			ecb    => sub {
				my ( $http, $error ) = @_;
				$self->error( $error ); 
				$self->ecb->( $self, $error );
			},
		);
		
		return;
	}
	
	$self->SUPER::_createHTTPRequest( $type, $url, @args );
}

sub _login_done {
	my $self   = shift;
	my $params = $self->params('params');
	
	my $json = eval { from_json( $self->content ) };
	
	if ( $@ ) {
		return $self->_error( $@ );
	}
	
	if ( $json->{error} ) {
		return $self->_error( $json->{error} );
	}
	
	if ( my $sid = $json->{sid}	) {
		$prefs->set( sn_session => $sid );
	}
	
	main::DEBUGLOG && $log->debug("Logged into SN OK");
	
	$params->{cb}->( $self, $json );
}

sub _error {
	my ( $self, $error ) = @_;
	my $params = $self->params('params');
	
	$log->error( "Unable to login to SN: $error" );
	
	$prefs->remove('sn_session');
	
	$self->error( $error );
	
	$params->{ecb}->( $self, $error );
}

sub _construct_url {
	my ( $self, $method, $params ) = @_;
	
	my $url = $self->url( '/api/v1/' . $method );
	
	if ( my @keys = keys %{$params} ) {
		my @params;
		foreach my $key ( @keys ) {
			push @params, uri_escape($key) . '=' . uri_escape( $params->{$key} );
		}
		$url .= '?' . join( '&', @params );
	}
	
	return $url;
}

1;
	
	
	
