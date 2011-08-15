package Slim::Schema::ResultSet::Genre;

# $Id: Genre.pm 32504 2011-06-07 12:16:25Z agrundman $

use strict;
use base qw(Slim::Schema::ResultSet::Base);

use Slim::Utils::Prefs;

sub searchColumn {
	my $self  = shift;

	return 'namesearch';
}

sub searchNames {
	my $self  = shift;
	my $terms = shift;
	my $attrs = shift || {};
	
	my $collate = Slim::Utils::OSDetect->getOS()->sqlHelperClass()->collate();

	$attrs->{'order_by'} ||= "me.namesort $collate";
	$attrs->{'distinct'} ||= 'me.id';

	return $self->search({ 'me.namesearch' => { 'like' => $terms } }, $attrs);
}

1;
