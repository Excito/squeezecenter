package Slim::Web::Pages::BrowseTree;

# $Id: BrowseTree.pm 28819 2009-10-12 17:27:13Z michael $

# Squeezebox Server Copyright 2001-2009 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License, 
# version 2.

use strict;

use POSIX ();
use Scalar::Util qw(blessed);

use Slim::Utils::Misc;
use Slim::Utils::Strings qw(string);
use Slim::Web::Pages;
use Slim::Utils::Prefs;

my $prefs = preferences('server');

sub init {
	
	Slim::Web::Pages->addPageFunction( qr/^browsetree\.(?:htm|xml)/, \&browsetree );
	
	if ($prefs->get('audiodir')) {
		Slim::Web::Pages->addPageLinks("browse",{'BROWSE_MUSIC_FOLDER'   => "browsetree.html"});
	} else {
		Slim::Web::Pages->addPageLinks("browse",{'BROWSE_MUSIC_FOLDER' => undef});
	}
}

sub browsetree {
	my ($client, $params) = @_;

	my $hierarchy  = $params->{'hierarchy'} || '';
	my $player     = $params->{'player'};
	my $itemsPer   = $params->{'itemsPerPage'} || $prefs->get('itemsPerPage');

	my @levels     = split(/\//, $hierarchy);
	my $itemnumber = 0;

	# Pull the directory list, which will be used for looping.
	my ($topLevelObj, $items, $count) = Slim::Utils::Misc::findAndScanDirectoryTree( { 'id' => $levels[-1] } );

	# if we have no level, we just sent undef to findAndScanDirectoryTree with our $levels[-1]
	# findAndScanDirectoryTree will fall back to some sensible default if sent undef
	# use this sensible default to create the @levels array
	if (!scalar(@levels)) {
		# FIXME?: this will die if findAndScanDirectoryTree does not return a valid $topLevelObj
		push @levels, $topLevelObj->id();
	}

	# Page title
	$params->{'browseby'} = 'BROWSE_MUSIC_FOLDER';
	$params->{'icons'}    = $Slim::Web::Pages::additionalLinks{icons};

	for (my $i = 0; $i < scalar @levels; $i++) {

		my $obj = Slim::Schema->find('Track', $levels[$i]);

		if (blessed($obj) && $obj->can('title')) {

			push @{$params->{'pwd_list'}}, {
				'hreftype'     => 'browseTree',
				'title'        => $i == 0 ? string('BROWSE_MUSIC_FOLDER') :
						($obj->title ? $obj->title : Slim::Music::Info::fileName($obj->url)),
				'hierarchy'    => join('/', @levels[0..$i]),
			};
		}
	}

	my ($start, $end) = (0, $count);

	$params->{'pageinfo'} = Slim::Web::Pages::Common->pageInfo({
		'itemCount'    => $count,
		'path'         => $params->{'path'},
		'otherParams'  => "&hierarchy=$hierarchy&player=$player",
		'start'        => $params->{'start'},
		'perPage'      => $params->{'itemsPerPage'},
	});

	$start = $params->{'start'} = $params->{'pageinfo'}{'startitem'};
	$end = $params->{'pageinfo'}{'enditem'};

	# Setup an 'All' button.
	# I believe this will play only songs, and not playlists.
	if ($count) {
		my %form = %$params;

		$form{'hierarchy'}   = undef;
		$form{'descend'}     = 1;
		$form{'text'}        = string('ALL_SONGS');
		$form{'itemobj'}     = $topLevelObj;
		$form{'hreftype'}    = 'browseTree';

		push @{$params->{'browse_items'}}, \%form;
	}

	my $topPath = $topLevelObj->path;

	for my $relPath (@$items[$start..$end]) {

		my $url  = Slim::Utils::Misc::fixPath($relPath, $topPath) || next;
		my $name;

		# Do the cheap compare for osName first - so non-windows users
		# won't take the penalty for the lookup.
		if (main::ISWINDOWS && Slim::Music::Info::isWinShortcut($url)) {
			($name, $url) = Slim::Utils::OS::Win32->getShortcut($url);
			$name = Slim::Utils::Unicode::utf8on($name);
		}

		my $item = Slim::Schema->objectForUrl({
			'url'      => $url,
			'create'   => 1,
			'readTags' => 1,
		});

		if (!blessed($item) || !$item->can('content_type')) {
			next;
		}

		# Bug: 1360 - Don't show files referenced in a cuesheet
		next if ($item->content_type eq 'cur');

		# allow descending if current item is a Mac alias pointing to a folder
		my $descend = Slim::Music::Info::isList($item) 
						|| ($item->content_type eq 'unk' && -d Slim::Utils::Misc::pathFromMacAlias($url));

		my %form = (
			'text'      => $name || Slim::Music::Info::fileName($url),
			'hierarchy' => join('/', @levels, $item->id),
			'descend'   => $descend,
			'odd'       => ($itemnumber + 1) % 2,
			'itemobj'   => $item,
			'hreftype'  => 'browseTree',
		);

		# Don't display the edit dialog for playlists (includes CUE sheets).
		if ($item->isPlaylist) {

			$form{'hreftype'}   = 'browseDb';
			$form{'hierarchy'}  = 'playlist,playlistTrack';
			$form{'level'}      = 1;
			$form{'attributes'} = sprintf('&noEdit=1&playlist.id=%d', $item->id);
		}

		$itemnumber++;

		push @{$params->{'browse_items'}}, \%form;

		if (!$params->{'coverArt'} && $item->coverArtExists) {
			$params->{'coverArt'} = $item->id;
		}
	}

	$params->{'descend'} = 1;
	
	if (Slim::Music::Import->stillScanning()) {
		$params->{'warn'} = 1;
	}

	# we might have changed - flush to the db to be in sync.
	$topLevelObj->update;

	return Slim::Web::HTTP::filltemplatefile("browsedb.html", $params);
}

1;

__END__
