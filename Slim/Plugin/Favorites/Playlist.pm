package Slim::Plugin::Favorites::Playlist;

# $Id: Playlist.pm 13299 2007-09-27 08:59:36Z mherger $

# Class to allow importing of playlist formats understood by SqueezeCenter into opml files

use File::Basename;
use File::Spec::Functions qw(:ALL);

use Slim::Utils::Log;
use Slim::Utils::Prefs;

use strict;

my $log = logger('favorites');

my $prefsServer = preferences('server');

sub read {
	my $class = shift;
	my $name  = shift;

	if ($name =~ /^file\:\/\//) {

		$name = Slim::Utils::Misc::pathFromFileURL($name);

	} elsif (dirname($name) eq '.') {

		$name = catdir($prefsServer->get('playlistdir'), $name);
	}

	my $type = Slim::Music::Info::contentType($name);
	my $playlistClass = Slim::Formats->classForFormat($type);

	if (-r $name && $type && $playlistClass) {

		Slim::Formats->loadTagFormatForType($type);

		my $fh = FileHandle->new($name);

		my @results = Slim::Plugin::Favorites::PlaylistWrapper->read($fh, $playlistClass);

		close($fh);

		if ( $log->is_info ) {
			$log->info(sprintf "Imported %d items from playlist %s", scalar @results, $name);
		}

		return \@results;

	} else {

		$log->warn("Unable to import from $name");

		return undef;
	}
}

1;


package Slim::Plugin::Favorites::PlaylistWrapper;

# subclass the normal server format classes to avoid loading any data into the database
# and return elements in the format of opml hash entries

our @ISA;

sub read {
	my $class         = shift;
	my $fh            = shift;
	my $playlistClass = shift;

	@ISA = ( $playlistClass );

	return $class->SUPER::read($fh);
}

sub _updateMetaData {
	my $class = shift;
	my $entry = shift;
	my $attib = shift;

	# return an opml entry in hash format
	return {
		'URL'  => $entry,
		'text' => $attib->{'TITLE'},
		'type' => 'audio',
	};
}

1;
