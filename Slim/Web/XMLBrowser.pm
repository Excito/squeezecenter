package Slim::Web::XMLBrowser;

# $Id: XMLBrowser.pm 30273 2010-02-26 19:17:14Z agrundman $

# Squeezebox Server Copyright 2001-2009 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License, 
# version 2.

# This class displays a generic web interface for XML feeds

use strict;

use URI::Escape qw(uri_unescape);
use List::Util qw(min);

use Slim::Formats::XML;
use Slim::Player::ProtocolHandlers;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Strings qw(string);
use Slim::Utils::Favorites;
use Slim::Web::HTTP;
use Slim::Web::Pages;

use constant CACHE_TIME => 3600; # how long to cache browse sessions

my $log = logger('formats.xml');

sub handleWebIndex {
	my ( $class, $args ) = @_;

	my $client    = $args->{'client'};
	my $feed      = $args->{'feed'};
	my $type      = $args->{'type'} || 'link';
	my $path      = $args->{'path'} || 'index.html';
	my $title     = $args->{'title'};
	my $expires   = $args->{'expires'};
	my $timeout   = $args->{'timeout'};
	my $asyncArgs = $args->{'args'};
	my $item      = $args->{'item'} || {};
	my $pageicon  = $Slim::Web::Pages::additionalLinks{icons}{$title};
	
	# If the feed is already XML data (Podcast List), send it to handleFeed
	if ( ref $feed eq 'HASH' ) {

		handleFeed( $feed, {
			'url'     => $feed->{'url'},
			'path'    => $path,
			'title'   => $title,
			'expires' => $expires,
			'args'    => $asyncArgs,
			'pageicon'=> $pageicon
		} );

		return;
	}
	
	my $params = {
		'client'  => $client,
		'url'     => $feed,
		'type'    => $type,
		'path'    => $path,
		'title'   => $title,
		'expires' => $expires,
		'timeout' => $timeout,
		'args'    => $asyncArgs,
		'pageicon'=> $pageicon,
	};
	
	# Handle plugins that want to use callbacks to fetch their own URLs
	if ( ref $feed eq 'CODE' ) {
		my $callback = sub {
			my $menu = shift;
			
			if ( ref $menu ne 'ARRAY' ) {
				$menu = [ $menu ];
			}
			
			my $opml = {
				type  => 'opml',
				title => $title,
				items => $menu,
			};
			
			handleFeed( $opml, $params );
		};
		
		# get passthrough params if supplied
		my $pt = $item->{'passthrough'} || [];
		
		if ( main::DEBUGLOG && $log->is_debug ) {
			my $cbname = Slim::Utils::PerlRunTime::realNameForCodeRef($feed);
			$log->debug( "Fetching OPML from coderef $cbname" );
		}
		
		return $feed->( $client, $callback, @{$pt} );
	}
	
	# Handle type = search at the top level, i.e. Radio Search
	if ( $type eq 'search' ) {
		my $query = $asyncArgs->[1]->{q};
		
		if ( !$query ) {
			my $index = $asyncArgs->[1]->{index};
			($query) = $index =~ m/^_([^.]+)/;
		}
		
		$params->{url} =~ s/{QUERY}/$query/g;
	}
	
	# Lookup this browse session in cache if user is browsing below top-level
	# This avoids repated lookups to drill down the menu
	my $index = $params->{args}->[1]->{index};
	if ( $index && $index =~ /^([a-f0-9]{8})/ ) {
		my $sid = $1;
		
		# Do not use cache if this is a search query
		if ( $asyncArgs->[1]->{q} ) {
			# Generate a new sid
			my $newsid = Slim::Utils::Misc::createUUID();
			
			$params->{args}->[1]->{index} =~ s/^$sid/$newsid/;
		}
		else {
			my $cache = Slim::Utils::Cache->new;
			if ( my $cached = $cache->get("xmlbrowser_$sid") ) {
				main::DEBUGLOG && $log->is_debug && $log->debug( "Using cached session $sid" );
				
				handleFeed( $cached, $params );
				return;
			}
		}
	}

	# fetch the remote content
	Slim::Formats::XML->getFeedAsync(
		\&handleFeed,
		\&handleError,
		$params,
	);

	return;
}

sub handleFeed {
	my ( $feed, $params ) = @_;
	my ( $client, $stash, $callback, $httpClient, $response ) = @{ $params->{'args'} };
	
	my $cache = Slim::Utils::Cache->new;

	$stash->{'pagetitle'} = $feed->{'title'} || Slim::Utils::Strings::getString($params->{'title'});
	$stash->{'pageicon'}  = $params->{pageicon};

	my $template = 'xmlbrowser.html';
	
	# Session ID for this browse session
	my $sid;
		
	# select the proper list of items
	my @index = ();

	if ( defined $stash->{'index'} && length( $stash->{'index'} ) ) {
		@index = split /\./, $stash->{'index'};
		
		if ( length( $index[0] ) >= 8 ) {
			# Session ID is first element in index
			$sid = shift @index;
		}
	}
	else {
		# Create a new session ID, unless the list has coderefs
		my $refs = scalar grep { ref $_->{url} } @{ $feed->{items} };
		
		if ( !$refs ) {
			$sid = Slim::Utils::Misc::createUUID();
		}
	}
	
	# breadcrumb
	my @crumb = ( {
		'name'  => $feed->{'title'} || Slim::Utils::Strings::getString($params->{'title'}),
		'index' => $sid,
	} );
	
	# Persist search query from top level item
	if ( $params->{type} && $params->{type} eq 'search' ) {
		$crumb[0]->{index} = '_' . $stash->{q};
	};

	# favorites class to allow add/del of urls to favorites, but not when browsing favorites list itself
	my $favs = Slim::Utils::Favorites->new($client) unless $feed->{'favorites'};
	my $favsItem;

	# action is add/delete favorite: pop the last item off the index as we want to display the whole page not the item
	# keep item id in $favsItem so we can process it later
	if ($stash->{'action'} && $stash->{'action'} =~ /^(favadd|favdel)$/ && @index) {
		$favsItem = pop @index;
	}
	
	if ( $sid ) {
		# Cache the feed structure for this session

		# cachetime is only set by parsers which known the content is dynamic and so can't be cached
		# for all other cases we always cache for CACHE_TIME to ensure the menu stays the same throughout the session
		my $cachetime = defined $feed->{'cachetime'} ? $feed->{'cachetime'} : CACHE_TIME;

		main::DEBUGLOG && $log->is_debug && $log->debug( "Caching session $sid for $cachetime" );

		eval { $cache->set( "xmlbrowser_$sid", $feed, $cachetime ) };
		
		if ( $@ && $log->is_warn ) {
			$log->warn("Session not cached: $@");
		}
	}

	if ( my $levels = scalar @index ) {
		
		# index links for each crumb item
		my @crumbIndex = $sid ? ( $sid ) : ();
		
		# descend to the selected item
		my $depth = 0;
		
		my $subFeed = $feed;
		for my $i ( @index ) {
			$depth++;
			
			$subFeed = $subFeed->{'items'}->[$i];
			
			push @crumbIndex, $i;
			my $crumbText = join '.', @crumbIndex;
			
			my $crumbName = $subFeed->{'name'} || $subFeed->{'title'};
			
			# Add search query to crumb list
			my $searchQuery;
			
			if ( $subFeed->{'type'} && $subFeed->{'type'} eq 'search' && $stash->{'q'} ) {
				$crumbText .= '_' . $stash->{'q'};
				$searchQuery = $stash->{'q'};
			}
			elsif ( $i =~ /(?:\d+)?_(.+)/ ) {
				$searchQuery = $1;
			}
			
			# Add search query to crumbName
			if ( $searchQuery ) {
				$crumbName .= ' (' . $searchQuery . ')';
			}
			
			push @crumb, {
				'name'  => $crumbName,
				'index' => $crumbText,
			};

			# Change type to audio if it's an action request and we have a play attribute
			# and it's the last item
			if ( 
				   $subFeed->{'play'} 
				&& $depth == $levels
				&& $stash->{'action'} =~ /^(?:play|add)$/
			) {
				$subFeed->{'type'} = 'audio';
			}
			
			# Change URL if there is a playlist attribute and it's the last item
			if ( 
			       $subFeed->{'playlist'}
				&& $depth == $levels
				&& $stash->{'action'} =~ /^(?:playall|addall)$/
			) {
				$subFeed->{'type'} = 'playlist';
				$subFeed->{'url'}  = $subFeed->{'playlist'};
			}
			
			# Bug 15343, if we are at the lowest menu level, and we have already
			# fetched and cached this menu level, check if we should always
			# re-fetch this menu. This is used to ensure things like the Pandora
			# station list are always up to date. The reason we check depth==levels
			# is so that when you are browsing at a lower level we don't allow
			# the parent menu to be refreshed out from under the user
			if ( $depth == $levels && $subFeed->{fetched} && $subFeed->{forceRefresh} && !$params->{fromSubFeed} ) {
				main::DEBUGLOG && $log->is_debug && $log->debug("  Forcing refresh of menu");
				delete $subFeed->{fetched};
			}
			
			# If the feed is another URL, fetch it and insert it into the
			# current cached feed
			$subFeed->{'type'} ||= '';
			if ( $subFeed->{'type'} ne 'audio' && defined $subFeed->{'url'} && !$subFeed->{'fetched'} &&
					 !( $stash->{'action'} && $stash->{'action'} =~ /favadd|favdel/ && $depth == $levels ) ) {
				
				# Rewrite the URL if it was a search request
				if ( $subFeed->{'type'} eq 'search' && ( $stash->{'q'} || $searchQuery ) ) {
					my $search = $stash->{'q'} || $searchQuery;
					$subFeed->{'url'} =~ s/{QUERY}/$search/g;
				}
				
				# Setup passthrough args
				my $args = {
					'client'       => $client,
					'item'         => $subFeed,
					'url'          => $subFeed->{'url'},
					'path'         => $params->{'path'},
					'feedTitle'    => $subFeed->{'name'} || $subFeed->{'title'},
					'parser'       => $subFeed->{'parser'},
					'expires'      => $params->{'expires'},
					'timeout'      => $params->{'timeout'},
					'parent'       => $feed,
					'parentURL'    => $params->{'parentURL'} || $params->{'url'},
					'currentIndex' => \@crumbIndex,
					'args'         => [ $client, $stash, $callback, $httpClient, $response ],
					'pageicon'     => $params->{'pageicon'}
				};
				
				if ( ref $subFeed->{'url'} eq 'CODE' ) {
					my $callback = sub {
						my $menu = shift;

						if ( ref $menu ne 'ARRAY' ) {
							$menu = [ $menu ];
						}

						my $opml = {
							type  => 'opml',
							title => $args->{feedTitle},
							items => $menu,
						};

						handleSubFeed( $opml, $args );
					};

					# get passthrough params if supplied
					my $pt = $subFeed->{'passthrough'} || [];

					if ( main::DEBUGLOG && $log->is_debug ) {
						my $cbname = Slim::Utils::PerlRunTime::realNameForCodeRef( $subFeed->{url} );
						$log->debug( "Fetching OPML from coderef $cbname" );
					}

					# first param is a $client object, but undef from webpages
					return $subFeed->{url}->( $client, $callback, @{$pt} );
				}
				
				# Check for a cached version of this subfeed URL
				if ( my $cached = Slim::Formats::XML->getCachedFeed( $subFeed->{'url'} ) ) {
					main::DEBUGLOG && $log->debug( "Using previously cached subfeed data for $subFeed->{url}" );
					handleSubFeed( $cached, $args );
				}
				else {
					# We need to fetch the URL
					Slim::Formats::XML->getFeedAsync(
						\&handleSubFeed,
						\&handleError,
						$args,
					);
				}
				
				return;
			}
		}
			
		# If the feed contains no sub-items, display item details
		if ( !$subFeed->{'items'} 
			 ||
			 ( ref $subFeed->{'items'} eq 'ARRAY' && !scalar @{ $subFeed->{'items'} } ) 
		) {
			$subFeed->{'image'} = $subFeed->{'image'} || Slim::Player::ProtocolHandlers->iconForURL($subFeed->{'play'} || $subFeed->{'url'});

			$stash->{'streaminfo'} = {
				'item'  => $subFeed,
				'index' => $sid ? join( '.', $sid, @index ) : join( '.', @index ),
			};
		}
		
		# Construct index param for each item in the list
		my $itemIndex = $sid ? join( '.', $sid, @index ) : join( '.', @index );
		if ( $stash->{'q'} ) {
			$itemIndex .= '_' . $stash->{'q'};
		}
		$itemIndex .= '.';
		
		$stash->{'pagetitle'} = $subFeed->{'name'} || $subFeed->{'title'};
		$stash->{'crumb'}     = \@crumb;
		$stash->{'items'}     = $subFeed->{'items'};
		$stash->{'index'}     = $itemIndex;
		$stash->{'image'}     = $subFeed->{'image'};
	}
	else {
		$stash->{'pagetitle'} = $feed->{'title'} || $feed->{'name'} || Slim::Utils::Strings::getString($params->{'title'});
		$stash->{'crumb'}     = \@crumb;
		$stash->{'items'}     = $feed->{'items'};
		
		if ( $sid ) {
			$stash->{index} = $sid;
		}
		
		# Persist search term from top-level item (i.e. Search Radio)
		if ( $stash->{q} ) {
			$stash->{index} .= '_' . $stash->{q};
		}
		
		if ( $stash->{index} ) {
			$stash->{index} .= '.';
		}

		if (defined $favsItem) {
			$stash->{'index'} = undef;
		}
	}
	
	# play/add stream
	if ( $client && $stash->{'action'} && $stash->{'action'} =~ /^(play|add)$/ ) {
		my $play  = ($stash->{'action'} eq 'play');
		my $url   = $stash->{'streaminfo'}->{'item'}->{'url'};
		my $title = $stash->{'streaminfo'}->{'item'}->{'name'} 
			|| $stash->{'streaminfo'}->{'item'}->{'title'};
		
		# Podcast enclosures
		if ( my $enc = $stash->{'streaminfo'}->{'item'}->{'enclosure'} ) {
			$url = $enc->{'url'};
		}
		
		# Items with a 'play' attribute will use this for playback
		if ( my $play = $stash->{'streaminfo'}->{'item'}->{'play'} ) {
			$url = $play;
		}
		
		if ( $url ) {

			main::INFOLOG && $log->info("Playing/adding $url");
			
			# Set metadata about this URL
			Slim::Music::Info::setRemoteMetadata( $url, {
				title   => $title,
				ct      => $stash->{'streaminfo'}->{'item'}->{'mime'},
				secs    => $stash->{'streaminfo'}->{'item'}->{'duration'},
				bitrate => $stash->{'streaminfo'}->{'item'}->{'bitrate'},
			} );
		
			if ( $play ) {
				$client->execute([ 'playlist', 'play', $url ]);
			}
			else {
				$client->execute([ 'playlist', 'add', $url ]);
			}
		
			my $webroot = $stash->{'webroot'};
			$webroot =~ s/(.*?)plugins.*$/$1/;
			$template = 'xmlbrowser_redirect.html';
		}
	}
	# play all/add all
	elsif ( $client && $stash->{'action'} && $stash->{'action'} =~ /^(playall|addall)$/ ) {
		my $play  = ($stash->{'action'} eq 'playall');
		
		my @urls;
		# XXX: Why is $stash->{streaminfo}->{item} added on here, it seems to be undef?
		for my $item ( @{ $stash->{'items'} }, $stash->{'streaminfo'}->{'item'} ) {
			my $url;
			if ( $item->{'type'} eq 'audio' && $item->{'url'} ) {
				$url = $item->{'url'};
			}
			elsif ( $item->{'enclosure'} && $item->{'enclosure'}->{'url'} ) {
				$url = $item->{'enclosure'}->{'url'};
			}
			elsif ( $item->{'play'} ) {
				$url = $item->{'play'};
			}
			
			next if !$url;
			
			# Set metadata about this URL
			Slim::Music::Info::setRemoteMetadata( $url, {
				title   => $item->{'name'} || $item->{'title'},
				ct      => $item->{'mime'},
				secs    => $item->{'duration'},
				bitrate => $item->{'bitrate'},
			} );
			
			main::idleStreams();
			
			push @urls, $url;
		}
		
		if ( @urls ) {

			if ( main::INFOLOG && $log->is_info ) {
				$log->info(sprintf("Playing/adding all items:\n%s", join("\n", @urls)));
			}
			
			if ( $play ) {
				$client->execute([ 'playlist', 'play', \@urls ]);
			}
			else {
				$client->execute([ 'playlist', 'add', \@urls ]);
			}

			my $webroot = $stash->{'webroot'};
			$webroot =~ s/(.*?)plugins.*$/$1/;
			$template = 'xmlbrowser_redirect.html';
		}
	}
	else {
		
		# Check if any of our items contain audio as well as a duration value, so we can display an
		# 'All Songs' link.  Lists with no duration values are lists of radio stations where it doesn't
		# make sense to have an All Songs link. (bug 6531)
		for my $item ( @{ $stash->{'items'} } ) {
			next unless ( $item->{'type'} && $item->{'type'} eq 'audio' ) || $item->{'enclosure'} || $item->{'play'};
			next unless defined $item->{'duration'};

			$stash->{'itemsHaveAudio'} = 1;
			$stash->{'currentIndex'}   = $crumb[-1]->{index};
			last;
		}
		
		my $itemCount = scalar @{ $stash->{'items'} };
		
		my $clientId = ( $client ) ? $client->id : undef;
		my $otherParams = '&index=' . $crumb[-1]->{index} . '&player=' . $clientId;
		if ( $stash->{'query'} ) {
			$otherParams = '&query=' . $stash->{'query'} . $otherParams;
		}
			
		$stash->{'pageinfo'} = Slim::Web::Pages::Common->pageInfo({
				'itemCount'   => $itemCount,
				'path'        => $params->{'path'} || 'index.html',
				'otherParams' => $otherParams,
				'start'       => $stash->{'start'},
				'perPage'     => $stash->{'itemsPerPage'},
		});
		
		$stash->{'start'} = $stash->{'pageinfo'}{'startitem'};
		
		$stash->{'path'} = $params->{'path'} || 'index.html';

		if ($stash->{'pageinfo'}{'totalpages'} > 1) {

			# the following ensures the original array is not altered by creating a slice to show this page only
			my $start = $stash->{'start'};
			my $finish = $start + $stash->{'pageinfo'}{'itemsperpage'};
			$finish = $itemCount if ($itemCount < $finish);

			my @items = @{ $stash->{'items'} };
			my @slice = @items [ $start .. $finish - 1 ];
			$stash->{'items'} = \@slice;
		}

		if ($stash->{'path'} =~ /trackinfo.html/) {
			my $details = {};
			my $mixerlinks = {};
			my $i = 0;
			
			foreach my $item ( @{ $stash->{'items'} } ) {

				# Bug 7854, don't set an index value unless we're at the top-level trackinfo page
				if ( !$stash->{'index'} ) {
					$item->{'index'} = $i;
				}

				if ($item->{'web'} && (my $group = $item->{'web'}->{'group'})) {

					if ($item->{'web'}->{'type'} && $item->{'web'}->{'type'} eq 'contributor') {

						$details->{'contributors'} ||= {};
						$details->{'contributors'}->{$group} ||= [];

						push @{ $details->{'contributors'}->{ $group } }, {
							name => $item->{'web'}->{'value'},
							id   => $item->{'db'}->{'findCriteria'}->{'contributor.id'},
						};

					}

					elsif ($group eq 'mixers') {
						
						$details->{'mixers'} ||= [];
						
						my $mixer = {
							item => $stash->{'sess'}
						};
						
						my ($mixerkey, $mixerlink) = each %{ $item->{'web'}->{'item'}->{'mixerlinks'} };
						$stash->{'mixerlinks'}->{$mixerkey} = $mixerlink;
						
						foreach ( keys %{ $item->{'web'}->{'item'}} ) {
							$mixer->{$_} = $item->{'web'}->{'item'}->{$_};
						}

						push @{ $details->{'mixers'} }, $mixer;
					}

					# unfold items which are folded for smaller UIs;
					elsif ($item->{'items'} && $item->{'web'}->{'unfold'}) {
						
						$details->{'unfold'} ||= [];
						
						my $new_index = 0;
						foreach my $moreItem ( @{ $item->{'items'} } ) {
							$moreItem->{'index'} = $item->{'index'} . '.' . $new_index;
							$new_index++;
						}
						
						push @{ $details->{'unfold'} }, {
							items => $item->{'items'},
							start => $i,
						};
					}
					
					else {
						
						$details->{$group} ||= [];
												
						push @{ $details->{$group} }, {
							name => $item->{'web'}->{'value'},
							id   => $item->{'db'}->{'findCriteria'}->{ $group . '.id' },
						};
					}
					
				}

				$i++;
			}

			# unfold nested groups of additional items
			my $new_index;
			foreach my $group (@{ $details->{'unfold'} }) {
				
				splice @{ $stash->{'items'} }, ($group->{'start'} + $new_index), 1, @{ $group->{'items'} };
				$new_index = $#{ $group->{'items'} };
			}

			$stash->{'details'} = $details;

		}
	}

	if ($favs) {
		my @items = @{$stash->{'items'} || []};
		my $start = $stash->{'start'} || 0;

		if (defined $favsItem && $items[$favsItem - $start]) {
			my $item = $items[$favsItem - $start];
			if ($stash->{'action'} eq 'favadd') {

				my $type = $item->{'type'} || 'link';
				
				if ( $item->{'play'} ) {
					$type = 'audio';
				}
				
				my $url = $item->{play} || $item->{url};
				
				# There may be an alternate URL for playlist
				if ( $type eq 'playlist' && $item->{playlist} ) {
					$url = $item->{playlist};
				}

				$favs->add(
					$url,
					$item->{'name'}, 
					$type, 
					$item->{'parser'}, 
					1, 
					$item->{'image'} || $item->{'icon'} || Slim::Player::ProtocolHandlers->iconForURL($item->{'play'} || $item->{'url'}) 
				);
			} elsif ($stash->{'action'} eq 'favdel') {
				$favs->deleteUrl( $item->{'play'} || $item->{'url'} );
			}
		}

		for my $item (@items) {
			if ($item->{'url'} && !defined $item->{'favorites'}) {
				$item->{'favorites'} = $favs->hasUrl( $item->{'play'} || $item->{'url'} ) ? 2 : 1;
			}
		}
	}

	my $output = processTemplate($template, $stash);
	
	# done, send output back to Web module for display
	$callback->( $client, $stash, $output, $httpClient, $response );
}

sub handleError {
	my ( $error, $params ) = @_;
	my ( $client, $stash, $callback, $httpClient, $response ) = @{ $params->{'args'} };
	
	my $template = 'xmlbrowser.html';
	
	my $title = ( uc($params->{title}) eq $params->{title} ) ? Slim::Utils::Strings::getString($params->{title}) : $params->{title};
	
	$stash->{'pagetitle'} = $title;
	$stash->{'pageicon'}  = $params->{pageicon};
	$stash->{'msg'} = sprintf(string('WEB_XML_ERROR'), $title, $error);
	
	my $output = processTemplate($template, $stash);
	
	# done, send output back to Web module for display
	$callback->( $client, $stash, $output, $httpClient, $response );
}

# Fetch a feed URL that is referenced within another feed.
# After fetching, insert the contents into the original feed
sub handleSubFeed {
	my ( $feed, $params ) = @_;
	my ( $client, $stash, $callback, $httpClient, $response ) = @{ $params->{'args'} };
	
	# If there's a command we need to run, run it.  This is used in various
	# places to trigger actions from an OPML result, such as to start playing
	# a new Pandora radio station
	if ( $feed->{'command'} && $client ) {
		my @p = map { uri_unescape($_) } split / /, $feed->{command};
		main::DEBUGLOG && $log->is_debug && $log->debug( "Executing command: " . Data::Dump::dump(\@p) );
		$client->execute( \@p );
	}
	
	# find insertion point for sub-feed data in the original feed
	my $parent = $params->{'parent'};
	my $subFeed = $parent;
	for my $i ( @{ $params->{'currentIndex'} } ) {
		# Skip sid and sid + top-level search query
		next if length($i) >= 8 && $i =~ /^[a-f0-9]{8}/;
		
		# If an index contains a search query, strip it out
		$i =~ s/_.+$//g;
		
		$subFeed = $subFeed->{'items'}->[$i];
	}

	if ($subFeed->{'type'} && 
		($subFeed->{'type'} eq 'replace' || 
		 ($subFeed->{'type'} eq 'playlist' && $subFeed->{'parser'} && scalar @{ $feed->{'items'} } == 1) ) ) {
		# in the case of a replace entry or playlist of one with parser update previous entry to avoid adding a new menu level
		my $item = $feed->{'items'}[0];
		if ($subFeed->{'type'} eq 'replace') {
			delete $subFeed->{'url'};
		}
		for my $key (keys %$item) {
			$subFeed->{ $key } = $item->{ $key };
		}
	} else {
		# otherwise insert items as subfeed
		$subFeed->{'items'} = $feed->{'items'};
	}

	# set flag to avoid fetching this url again
	$subFeed->{'fetched'} = 1;
	
	# Pass-through forceRefresh flag
	if ( $feed->{forceRefresh} ) {
		$subFeed->{forceRefresh} = 1;
	}
	
	# Mark this as coming from subFeed, so that we know to ignore forceRefresh
	$params->{fromSubFeed} = 1;

	# cachetime will only be set by parsers which know their content is dynamic
	if (defined $feed->{'cachetime'}) {
		$parent->{'cachetime'} = min( $parent->{'cachetime'} || CACHE_TIME, $feed->{'cachetime'} );
	}

	# No caching for callback-based plugins
	# XXX: this is a bit slow as it has to re-fetch each level
	if ( ref $subFeed->{'url'} eq 'CODE' ) {
		
		# Clear passthrough data as it won't be needed again
		delete $subFeed->{'passthrough'};
	}
	
	handleFeed( $parent, $params );
}

sub processTemplate {
	return Slim::Web::HTTP::filltemplatefile( @_ );
}

1;
