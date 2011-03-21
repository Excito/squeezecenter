package Slim::Plugin::OPMLBased;

# $Id$

# Base class for all plugins that use OPML feeds

use strict;
use base 'Slim::Plugin::Base';

use Slim::Utils::Prefs;

my $prefs = preferences('server');

my %cli_next = ();

sub initPlugin {
	my ( $class, %args ) = @_;
	
	{
		no strict 'refs';
		*{$class.'::'.'feed'} = sub { $args{feed} } if $args{feed};
		*{$class.'::'.'tag'}  = sub { $args{tag} };
		*{$class.'::'.'menu'} = sub { $args{menu} };
	}

	if (!$class->_pluginDataFor('icon')) {

		Slim::Web::Pages->addPageLinks("icons", { $class->getDisplayName => 'html/images/radio.png' });
	}
	
	$class->initCLI( %args );
	
	$class->initJive( %args );

	$class->SUPER::initPlugin();
}

# add "hidden" items to Jive home menu for individual OPMLbased items
# this allows individual items to be optionally added to the 
# top-level menu through the CustomizeHomeMenu applet
sub initJive {
	my ( $class, %args ) = @_;

	my $icon   = $class->_pluginDataFor('icon') ? $class->_pluginDataFor('icon') : 'html/images/radio.png';
	my $name = $class->getDisplayName();
        my @jiveMenu = ({
		stringToken    => $name,
		id             => 'opml' . $args{tag},
		node           => $args{menu},
		displayWhenOff => 0,
		window         => { 
				'icon-id' => $icon,
				titleStyle => 'album',
		},
		actions => {
			go =>          {
				player => 0,
				cmd    => [ $args{tag}, 'items' ],
				params => {
					menu => $args{tag},
				},
			},
		},
	});

	Slim::Control::Jive::registerPluginMenu(\@jiveMenu);
}

sub initCLI {
	my ( $class, %args ) = @_;
	
	my $cliQuery = sub {
	 	my $request = shift;
		Slim::Buttons::XMLBrowser::cliQuery( $args{tag}, $class->feed( $request->client ), $request );
	};
	
	# CLI support
	Slim::Control::Request::addDispatch(
		[ $args{tag}, 'items', '_index', '_quantity' ],
	    [ 1, 1, 1, $cliQuery ]
	);
	
	Slim::Control::Request::addDispatch(
		[ $args{tag}, 'playlist', '_method' ],
		[ 1, 1, 1, $cliQuery ]
	);

	$cli_next{ $class } ||= {};
		
	$cli_next{ $class }->{ $args{menu} } = Slim::Control::Request::addDispatch(
		[ $args{menu}, '_index', '_quantity' ],
		[ 0, 1, 1, $class->cliRadiosQuery( \%args, $args{menu} ) ]
	);
}

sub setMode {
	my ( $class, $client, $method ) = @_;

	if ($method eq 'pop') {

		Slim::Buttons::Common::popMode($client);
		return;
	}

	# use INPUT.Choice to display the list of feeds
	my $name = $class->getDisplayName();
	
	my %params = (
		header   => $name,
		modeName => $name,
		url      => $class->feed( $client ),
		title    => $client->string( $name ),
		timeout  => 35,
	);

	Slim::Buttons::Common::pushMode( $client, 'xmlbrowser', \%params );

	# we'll handle the push in a callback
	$client->modeParam( handledTransition => 1 );
}

sub cliRadiosQuery {
	my ( $class, $args, $cli_menu ) = @_;
	my $tag  = $args->{tag};

	my $icon   = $class->_pluginDataFor('icon') ? $class->_pluginDataFor('icon') : 'html/images/radio.png';
	my $weight = $args->{weight} || 100;

	return sub {
		my $request = shift;

		my $menu = $request->getParam('menu');

		$request->addParam('sort','weight');

		my $data;
		# what we want the query to report about ourself
		if (defined $menu) {
			$data = {
				text         => $request->string( $args->{display_name} || $class->getDisplayName() ),  # nice name
				weight       => $weight,
				'icon-id'    => $icon,
				actions      => {
						go => {
							cmd => [ $tag, 'items' ],
							params => {
								menu => $tag,
							},
						},
				},
				window        => {
					titleStyle => 'album',
				},
			};
			
			if ( main::SLIM_SERVICE ) {
				# Bug 7110, icons are full URLs so we must use icon not icon-id
				$data->{icon} = delete $data->{'icon-id'};
				
				# Bug 7230, send pre-thumbnailed URL
				$data->{icon} =~ s/\.png$/_56x56_p\.png/;
			}
		}
		else {
			$data = {
				cmd  => $tag,
				name => $request->string( $class->getDisplayName() ),
				type => 'xmlbrowser',
			};
		}
		
		# Exclude disabled plugins
		my $disabled = $prefs->get('sn_disabled_plugins');
		
		if ( main::SLIM_SERVICE ) {
			my $client = $request->client();
			$disabled  = [ keys %{ $client->playerData->userid->allowedServices->{disabled} } ];
			
			# Hide plugins if necessary (private, beta, etc)
			if ( !$client->playerData->userid->canSeePlugin($tag) ) {
				$data = {};
			}
		}
		
		if ( $disabled ) {
			for my $plugin ( @{$disabled} ) {
				if ( $class =~ /^Slim::Plugin::${plugin}::/ ) {
					$data = {};
					last;
				}
			}
		}
		
		# let our super duper function do all the hard work
		Slim::Control::Queries::dynamicAutoQuery( $request, $cli_menu, $cli_next{ $class }->{ $cli_menu }, $data );
	};
}

sub webPages {
	my $class = shift;

	my $title = $class->getDisplayName();
	my $url   = 'plugins/' . $class->tag() . '/index.html';
	
	Slim::Web::Pages->addPageLinks( $class->menu(), { $title => $url });

	Slim::Web::HTTP::addPageFunction( $url, sub {
		my $client = $_[0];
		
		Slim::Web::XMLBrowser->handleWebIndex( {
			client  => $client,
			feed    => $class->feed( $client ),
			title   => $title,
			timeout => 35,
			args    => \@_
		} );
	} );
}

1;
