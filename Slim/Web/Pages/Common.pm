package Slim::Web::Pages::Common;

# $Id: Common.pm 30714 2010-04-29 18:17:59Z agrundman $

# Squeezebox Server Copyright 2001-2009 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License, 
# version 2.

use strict;
use File::ReadBackwards;
use Scalar::Util qw(blessed);

use base qw(Slim::Web::Pages);

use Slim::Player::Playlist;
use Slim::Formats::Playlists::M3U;
use Slim::Player::Client;
use Slim::Utils::Log;
use Slim::Utils::Strings qw(string);
use Slim::Utils::Prefs;
use Slim::Utils::Progress;
use Slim::Web::HTTP;

my $prefs = preferences('server');

my $log    = logger('network.http');
my $sqllog = logger('database.sql');

our %hierarchy = (
	'artist' => 'album,track',
	'album'  => 'track',
	'song '  => '',
);

sub init(){

	Slim::Web::Pages->addPageFunction(qr/^firmware\.(?:html|xml)/,\&firmware);
	Slim::Web::Pages->addPageFunction(qr/^tunein\.(?:htm|xml)/,\&tuneIn);
	Slim::Web::Pages->addPageFunction(qr/^update_firmware\.(?:htm|xml)/,\&update_firmware);
	
}

sub _lcPlural {
	my ($class, $count, $singular, $plural) = @_;

	# only convert to lowercase if our language does not wand uppercase (default lc)
	my $word = ($count == 1 ? string($singular) : string($plural));
	$word = (string('MIDWORDS_UPPER') ? $word : lc($word));
	return sprintf("%s %s", $count, $word);
}

sub addLibraryStats {
	my ($class, $params, $rs, $previousLevel) = @_;
	
	if (!Slim::Schema::hasLibrary()) {
		return;
	}

	if (Slim::Music::Import->stillScanning) {

		$params->{'warn'} = 1;

		if (my $p = Slim::Schema->rs('Progress')->search({ 'type' => 'importer', 'active' => 1 })->first) {

			$params->{'progress'} = {
				'name' => $p->name,
				'bar'  => Slim::Web::Pages::Progress::progressBar($p, 40),
				'obj'  => $p,
			}
		}

		return;
	}

	if ($prefs->get('disableStatistics')) {

		$params->{'song_count'}   = 0;
		$params->{'album_count'}  = 0;
		$params->{'artist_count'} = 0;

		return;
	}

	my %counts = ();
	my $level  = $params->{'levelName'} || '';

	# Albums needs a roles check, as it doesn't go through contributors first.
	# if (defined $rs && !grep { 'contributorAlbums' } @{$rs->{'attrs'}->{'join'}}) {

	#	if (my $roles = Slim::Schema->artistOnlyRoles) {

			#$rs = $rs->search_related('contributorAlbums', {
			#	'contributorAlbums.role' => { 'in' => $roles }
			#});
	#	}
	#}

	# The current level will always be a ->browse call, so just reuse the resultset.
	if ($level eq 'album') {

		# Bug 3351
		if ( $previousLevel eq 'contributor' ) {
			# This avoids duplicate joins on contributorAlbums, the proper roles
			# are already selected since the $rs is already joined with contributorAlbums
			$counts{'contributor'} = $rs->search_related('contributor');
		}
		else {
			# filter out non-artist roles for contributor count
			my $cond  = {};
			my $roles = Slim::Schema->artistOnlyRoles('TRACKARTIST');
			if ( $roles ) {
				$cond->{'contributorAlbums.role'} = { 'in' => $roles };
			}
			$counts{'contributor'} = $rs->search_related('contributorAlbums')->search_related( 'contributor', $cond );
		}
		
		$counts{'album'} = $rs;
		$counts{'track'} = $rs->search_related('tracks');

	} elsif ($level eq 'contributor' && $previousLevel && $previousLevel eq 'genre') {
		
		# Bug 3351, we can't use the $rs here, because it's a contributor RS that is already
		# joined to genres.  We can use the genre RS that is stored in params however.
		my $genreTracks = $params->{'genre'}->search_related('genreTracks')->search_related('track');

		$counts{'album'}       = $genreTracks->search_related('album');
		$counts{'contributor'} = $rs;
		$counts{'track'}       = $genreTracks;

	} elsif ($level eq 'track') {
		
		# Bug 3351, filter out non-artist roles for contributor count
		my $cond = {};
		my $roles = Slim::Schema->artistOnlyRoles('TRACKARTIST');
		if ( $roles ) {
			$cond->{'contributorTracks.role'} = { 'in' => $roles };
		}
		
		$counts{'contributor'} = $rs->search_related('contributorTracks')->search_related( 'contributor', $cond );
		$counts{'album'}       = $rs->search_related('album');
		$counts{'track'}       = $rs;
		
	} else {

		$counts{'album'}       = Slim::Schema->rs('Album')->browse;
		$counts{'track'}       = Slim::Schema->rs('Track')->browse;
		$counts{'contributor'} = Slim::Schema->rs('Contributor')->browse;
	}

	# Don't let any database errors here stop the page from displaying
	eval {
		$params->{'song_count'}   = $class->_lcPlural($counts{'track'}->distinct->count, 'SONG', 'SONGS');
		$params->{'album_count'}  = $class->_lcPlural($counts{'album'}->distinct->count, 'ALBUM', 'ALBUMS'); 
		$params->{'artist_count'} = $class->_lcPlural($counts{'contributor'}->distinct->count, 'ARTIST', 'ARTISTS');
	};
	
	if ( $@ ) {
		$sqllog->error("Error building library counts: $@");
		
		$params->{'song_count'}   = 0;
		$params->{'album_count'}  = 0;
		$params->{'artist_count'} = 0;
	}

	if ( main::INFOLOG && $sqllog->is_info ) {
		$sqllog->info(sprintf("(Level: $level, previousLevel: $previousLevel) Found %s, %s & %s", 
			$params->{'song_count'}, $params->{'album_count'}, $params->{'artist_count'}
		));
	}
}

sub addSongInfo {
	my ($class, $client, $params, $getCurrentTitle) = @_;

	my $track = $params->{'itemobj'};
	my $id    = $params->{'item'};
	my $url;

	# kinda pointless, but keeping with compatibility
	if (!defined $track && !defined $id) {
		return;
	}

	if (ref($track) && !$track->can('id')) {
		return;
	}

	if ($track && !blessed($track)) {

		$track = Slim::Schema->objectForUrl({
			'url'      => $url,
			'create'   => 1,
			'readTags' => 1
		});

	} elsif ($id) {

		$track = Slim::Schema->find('Track', $id);
		$url   = $track->url() if $track;
	}

	$url   = $track->url() if $track;
	
	# Add plugin metadata if available
	if ( Slim::Music::Info::isRemoteURL($url) ) {
		my $handler = Slim::Player::ProtocolHandlers->handlerForURL( $url );
		if ( $handler && $handler->can('getMetadataFor') ) {
			$params->{'plugin_meta'} = $handler->getMetadataFor( $client, $url );

			# Strip extension from icon path
			if ( $params->{'plugin_meta'}->{'icon'} ) {
				$params->{'plugin_meta'}->{'icon'} =~ s/\.png$//;
			}
			
			# Only use cover if it's a full URL
			if ( $params->{'plugin_meta'}->{'cover'} && $params->{'plugin_meta'}->{'cover'} !~ /^http/ ) {
				delete $params->{'plugin_meta'}->{'cover'};
			}

		}
	}

	if (blessed($track) && $track->can('filesize')) {

		# let the template access the object directly.
		$params->{'itemobj'}    = $track unless $params->{'itemobj'};

		$params->{'filelength'} = Slim::Utils::Misc::delimitThousands($track->filesize);
		$params->{'bitrate'}    = $track->prettyBitRate;

		if ($getCurrentTitle) {
			$params->{'songtitle'} = Slim::Music::Info::getCurrentTitle($client, $track->url, 'web');
		} else {
			$params->{'songtitle'} = Slim::Music::Info::standardTitle(undef, $track);
		}

		$params->{favoritesEnabled} = Slim::Utils::Favorites->enabled;
		if ($params->{favoritesEnabled} && Slim::Music::Info::isURL($url)) {
			$params->{isFavorite} = defined Slim::Utils::Favorites->new($client)->findUrl($url);
		}

		# make urls in comments into links
		for my $comment ($track->comment) {

			next unless defined $comment && $comment !~ /^\s*$/;

			if (!($comment =~ s!\b(http://[A-Za-z0-9\-_\.\!~*'();/?:@&=+$,]+)!<a href=\"$1\" target=\"_blank\">$1</a>!igo)) {

				# handle emusic-type urls which don't have http://
				$comment =~ s!\b(www\.[A-Za-z0-9\-_\.\!~*'();/?:@&=+$,]+)!<a href=\"http://$1\" target=\"_blank\">$1</a>!igo;
			}

			$params->{'comment'} .= $comment;
		}
	
		# handle artwork bits
		if ($track->coverArt) {
			$params->{'coverThumb'} = $track->id;
		}

		if (Slim::Music::Info::isRemoteURL($url)) {

			$params->{'download'} = $url;

		} else {

			$params->{'download'} = sprintf('%smusic/%d/download', $params->{'webroot'}, $track->id);


			my $Imports = Slim::Music::Import->importers;
	
			$params->{mixeritems} = { item => $params->{item} };	
			for my $mixer (keys %{$Imports}) {
			
				if (defined $Imports->{$mixer}->{'mixerlink'}) {
					
					&{$Imports->{$mixer}->{'mixerlink'}}($track, $params->{mixeritems});

				}
			}
			$params->{mixerlinks} = $params->{mixeritems}->{mixerlinks};
		}
	}
}

sub addPlayerList {
	my ($class, $client, $params) = @_;

	$params->{'playercount'} = Slim::Player::Client::clientCount();
	
	my @players = Slim::Player::Client::clients();

	if (scalar(@players) > 1) {

		my %clientlist = ();

		for my $eachclient (@players) {

			$clientlist{$eachclient->id()} =  $eachclient->name();

			if ($eachclient->isSynced()) {
				$clientlist{$eachclient->id()} .= " (" . string('SYNCHRONIZED_WITH') . " " .
					$eachclient->syncedWithNames() .")";
			}	
		}

		$params->{'player_chooser_list'} = $class->options($client->id(), \%clientlist, $params->{'skinOverride'}, 50);
	}
}

sub options {
	my ($class, $selected, $option, $skinOverride, $truncate) = @_;

	# pass in the selected value and a hash of value => text pairs to get the option list filled
	# with the correct option selected.

	my $optionlist = '';

	for my $curroption (sort { $option->{$a} cmp $option->{$b} } keys %{$option}) {

		$optionlist .= ${Slim::Web::HTTP::filltemplatefile("select_option.html", {
			'selected'     => ($curroption eq $selected),
			'key'          => $curroption,
			'value'        => $option->{$curroption},
			'skinOverride' => $skinOverride,
			'maxLength'    => $truncate,
		})};
	}

	return $optionlist;
}


# Return a hashref with paging information, all list indexes are zero based
#
# named arguments:
# itemsRef : reference to the list of items
# itemCount : number of items in the list, not needed if itemsRef supplied
# otherParams : used to build the query portion of the url
# path : used to build the path portion of the url
# start : starting index of the displayed page in the list of items
# perPage : items per page to display, preference used by default
# addAlpha : flag determining whether to build the alpha map, requires itemsRef
# currentItem : the index of the "current" item in the list, 
#                if start not supplied this will be used to determine starting page
#
# Hash keys set:
# startitem : index in list of first item on page
# enditem : index in list of last item on page
# totalitems : number of items in the list
# itemsPerPage : number of items on each page
# currentpage : index of current page in list of pages
# totalpages : number of pages of items
# otherparams : as above
# path : as above
# alphamap : hash relating first character of sorted list to the index of the
#             first appearance of that character in the list.
# totalalphapages : total number of pages in alpha pagebar

sub pageInfo {
	my ($class, $args) = @_;
	
	my $results      = $args->{'results'};
	my $otherparams  = $args->{'otherParams'};
	my $start        = $args->{'start'};
	my $itemsPerPage = $args->{'perPage'} || $prefs->get('itemsPerPage');

	my %pageinfo  = ();
	my %alphamap  = ();
	my $itemCount = 0;
	my $end;

	# Use the ResultSet from pageBarResults to build our offset list.
	if ($args->{'addAlpha'}) {

		my $first = $results->first;

		$alphamap{ Encode::decode('utf8', $first->get_column('letter')) } = 0;

		$itemCount += $first->get_column('count');

		while (my $row = $results->next) {

			my $count  = $row->get_column('count');
			my $letter = $row->get_column('letter');

			# Set offset for subsequent letter rows to current # $itemCount
			# (*before* we add number of items for this letter to $itemCount!)
			$alphamap{ Encode::decode('utf8', $letter) } = $itemCount;

			$itemCount += $count;
		}

	} else {

		if ($args->{'itemCount'}) {

			$itemCount = $args->{'itemCount'}

		} elsif ($results) {

			$itemCount = $results->count;

		} else {

			$itemCount = 0;
		}
	}

	if (!$itemsPerPage || $itemsPerPage > $itemCount) {

		# we divide by this, so make sure it will never be 0
		$itemsPerPage = $itemCount || 1;
	}

	if (!defined($start) || $start eq '') {

		if ($args->{'currentItem'}) {

			$start = int($args->{'currentItem'} / $itemsPerPage) * $itemsPerPage;
		
		} else {

			$start = 0;
		}
	}

	if ($start >= $itemCount) {

		$start = $itemCount - $itemsPerPage;

		if ($start < 0) {
			$start = 0;
		}
	}
	
	$end = $start + $itemsPerPage - 1;

	if ($end >= $itemCount) {
		$end = $itemCount - 1;
	}

	# Don't let a negative end through.
	if ($end < 0) {
		$end = $itemCount;
	}

	$pageinfo{'enditem'}      = $end;
	$pageinfo{'totalitems'}   = $itemCount;
	$pageinfo{'itemsperpage'} = $itemsPerPage;
	$pageinfo{'currentpage'}  = int($start/$itemsPerPage);
	$pageinfo{'totalpages'}   = POSIX::ceil($itemCount/$itemsPerPage) || 0;
	$pageinfo{'otherparams'}  = defined($otherparams) ? $otherparams : '';
	$pageinfo{'path'}         = $args->{'path'};

	if ($args->{'addAlpha'} && $itemCount) {

		my @letterstarts = sort { $a <=> $b } values %alphamap;
		my @pagestarts   = $letterstarts[0];

		# some cases of alphamap shift the start index from 0, trap this.
		$start = $letterstarts[0] unless $args->{'start'} ;

		my $newend;

		for my $nextend (@letterstarts) {

			# check for overflow of alpha boundary, reset end to end of next alpha
			if ($nextend > $end && !defined($newend)) {
				$newend = $nextend - 1;
			}

			if ($pagestarts[0] + $itemsPerPage - 1 < $nextend) {

				# build pagestarts in descending order
				unshift @pagestarts, $nextend;
			}
		}

		# if last block and still no newend found, set it to the last of the list
		if (!defined($newend) && $itemCount > $end) {
			$newend = $itemCount - 1;
		}

		$pageinfo{'enditem'}         = $newend;
		$pageinfo{'totalalphapages'} = scalar(@pagestarts);

		KEYLOOP: for my $alphakey (keys %alphamap) {

			my $alphavalue = $alphamap{$alphakey};

			for my $pagestart (@pagestarts) {

				if ($alphavalue >= $pagestart) {

					$alphamap{$alphakey} = $pagestart;
					next KEYLOOP;
				}
			}
		}

		$pageinfo{'alphamap'} = \%alphamap;
	}

	# set the start index, accounding for alpha cases
	$pageinfo{'startitem'} = $start || 0;

	return \%pageinfo;
}

sub firmware {
	my ($client, $params) = @_;

	return Slim::Web::HTTP::filltemplatefile("firmware.html", $params);
}

# This is here just to support SDK4.x (version <=10) clients
# so it always sends an upgrade to version 10 using the old upgrade method.
sub update_firmware {
	my ($client, $params) = @_;

	$params->{'warning'} = Slim::Player::Squeezebox1::upgradeFirmware($params->{'ipaddress'}, 10) 
		|| string('UPGRADE_COMPLETE_DETAILS');
	
	return Slim::Web::HTTP::filltemplatefile("update_firmware.html", $params);
}

sub tuneIn {
	my ($client, $params) = @_;
	
	if ( $params->{'url'} ) {
		$client->execute( [ 
			'playlist', 
			$params->{'tuneInAdd'} ? 'add' : 'play', 
			$params->{'url'} 
		] );
	}
	
	return Slim::Web::HTTP::filltemplatefile('tunein.html', $params);
}

sub logFile {
	my ($class, $params, $response, $logfile) = @_;

	$response->header("Refresh" => "10; url=" . $params->{path} . ($params->{lines} ? '?lines=' . $params->{lines} : ''));
	$response->header("Content-Type" => "text/plain; charset=utf-8");
		
	$logfile =~ s/log/server/;
	$logfile .= 'LogFile';
		
	my $count = $params->{lines} || 50;

	my $body = '';

	my $file = File::ReadBackwards->new(Slim::Utils::Log->$logfile);
		
	if ($file){

		my @lines;
		while ( --$count && (my $line = $file->readline()) ) {
			unshift (@lines, $line);
		}
		$body .= join('', @lines);

		$file->close();			
	};		

	return ("text/plain", \$body)
}

sub downloadMusicFile {
	my ($class, $httpClient, $response, $track) = @_;

	my $obj = Slim::Schema->find('Track', $track);

	if (blessed($obj) && Slim::Music::Info::isSong($obj) && Slim::Music::Info::isFile($obj->url)) {

		main::INFOLOG && $log->is_info && $log->info("Opening $obj to stream...");
			
		my $ct = $Slim::Music::Info::types{$obj->content_type()};
			
		Slim::Web::HTTP::sendStreamingFile( $httpClient, $response, $ct, Slim::Utils::Misc::pathFromFileURL($obj->url) );
			
		return 1;
	}
}

sub statusTxt {
	my ($class, $client, $httpClient, $response, $params, $p) = @_;
	
	$response->header("Refresh" => "30; url=" . $params->{path});
	$response->header("Content-Type" => "text/plain; charset=utf-8");

	my $body;

	if ( $params->{path} =~ /status/ ) {
		# This code is deprecated. Jonas Salling is the only user
		# anymore, and we're trying to move him to use the CLI.
		buildStatusHeaders($client, $response, $p);

		if (defined($client)) {
			my $parsed = $client->curLines();
			my $line1 = $parsed->{line}[0] || '';
			my $line2 = $parsed->{line}[1] || '';
			$body = $line1 . $Slim::Web::HTTP::CRLF . $line2 . $Slim::Web::HTTP::CRLF;
		}
	}

	return ("text/plain", \$body)
}

sub buildStatusHeaders {
	my ($client, $response, $p) = @_;

	my %headers = ();
	
	if ($client) {

		# send headers
		%headers = ( 
			"x-player"		=> $client->id(),
			"x-playername"		=> $client->name(),
			"x-playertracks" 	=> Slim::Player::Playlist::count($client),
			"x-playershuffle" 	=> Slim::Player::Playlist::shuffle($client) ? "1" : "0",
			"x-playerrepeat" 	=> Slim::Player::Playlist::repeat($client),
		);
		
		if ($client->isPlayer()) {
	
			$headers{"x-playervolume"} = int($prefs->client($client)->get('volume') + 0.5);
			$headers{"x-playermode"}   = Slim::Buttons::Common::mode($client) eq "power" ? "off" : Slim::Player::Source::playmode($client);
	
			my $sleep = $client->sleepTime() - Time::HiRes::time();

			$headers{"x-playersleep"}  = $sleep < 0 ? 0 : int($sleep/60);
		}	
		
		if ($client && Slim::Player::Playlist::count($client)) { 

			my $track = Slim::Schema->objectForUrl(Slim::Player::Playlist::song($client));
	
			$headers{"x-playertrack"} = Slim::Player::Playlist::url($client); 
			$headers{"x-playerindex"} = Slim::Player::Source::streamingSongIndex($client) + 1;
			$headers{"x-playertime"}  = Slim::Player::Source::songTime($client);

			if (blessed($track) && $track->can('artist')) {

				my $i = $track->artist();
				$i = $i->name() if ($i);
				$headers{"x-playerartist"} = $i if $i;
		
				$i = $track->album();
				$i = $i->title() if ($i);
				$headers{"x-playeralbum"} = $i if $i;
		
				$i = $track->title();
				$headers{"x-playertitle"} = $i if $i;
		
				$i = $track->genre();
				$i = $i->name() if ($i);
				$headers{"x-playergenre"} = $i if $i;

				$i = $track->secs();				
				$headers{"x-playerduration"} = $i if $i;

				if ($track->coverArt()) {
					$headers{"x-playercoverart"} = "/music/" . $track->id() . "/cover.jpg";
				}
			}
		}
	}

	# include returned parameters if defined
	if (defined $p) {
		for (my $i = 0; $i < scalar @$p; $i++) {
	
			$headers{"x-p$i"} = $p->[$i];
		}
	}
	
	# simple quoted printable encoding
	while (my ($key, $value) = each %headers) {

		if (defined($value) && length($value)) {

			if ($] > 5.007 && Slim::Utils::Unicode::encodingFromString($value) ne 'ascii') {

				$value = Slim::Utils::Unicode::utf8encode($value, 'iso-8859-1');
				$value = encode_qp($value);
			}

			$response->header($key => $value);
		}
	}
}

sub statusM3u {
	my ($class, $client) = @_;
	
	# if the HTTP client has asked for a .m3u file, then always return the current playlist as an M3U
	if (defined($client)) {

		my $count = Slim::Player::Playlist::count($client) && do {
			return Slim::Formats::Playlists::M3U->write(\@{Slim::Player::Playlist::playList($client)});
		};
	}
}


# TODO: find where this is used?
#sub anchor {
#	my ($class, $item, $suppressArticles) = @_;
#	
#	if ($suppressArticles) {
#		$item = Slim::Utils::Text::ignoreCaseArticles($item) || return '';
#	}
#
#	return Slim::Utils::Text::matchCase(substr($item, 0, 1));
#}


# Build a simple header 
#sub simpleHeader {
#	my ($class, $args) = @_;
#	
#	my $itemCount    = $args->{'itemCount'};
#	my $startRef     = $args->{'startRef'};
#	my $headerRef    = $args->{'headerRef'};
#	my $skinOverride = $args->{'skinOverride'};
#	my $count		 = $args->{'perPage'} || $prefs->get('itemsPerPage');
#	my $offset		 = $args->{'offset'} || 0;
#
#	my $start = (defined($$startRef) && $$startRef ne '') ? $$startRef : 0;
#
#	if ($start >= $itemCount) {
#		$start = $itemCount - $count;
#	}
#
#	$$startRef = $start;
#
#	my $end    = $start + $count - 1 - $offset;
#
#	if ($end >= $itemCount) {
#		$end = $itemCount - 1;
#	}
#
#	# Don't bother with a pagebar on a non-pagable item.
#	if ($itemCount < $count) {
#		return ($start, $end);
#	}
#
#	$$headerRef = ${Slim::Web::HTTP::filltemplatefile("pagebarheader.html", {
#		"start"        => $start,
#		"end"          => $end,
#		"itemcount"    => $itemCount - 1,
#		'skinOverride' => $skinOverride
#	})};
#
#	return ($start, $end);
#}



1;
