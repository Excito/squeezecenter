package Slim::Utils::ChangeNotify::Win32;

# $Id: Win32.pm 8196 2006-06-29 03:54:53Z dsully $

use strict;
use base 'Class::Accessor::Fast';
use Win32::ChangeNotify;

use Slim::Utils::Misc;

__PACKAGE__->mk_accessors( qw[ notifier ] );

sub newWatcher {
	my $class = shift;

	my $self  = $class->SUPER::new();

	return $self;
}

sub addWatcher {
	my $self  = shift;
	my $args  = shift;

	my $entry = $args->{'dir'} || $args->{'file'};
	my $cb    = $args->{'callback'};

	if ($entry && ref($cb) eq 'CODE') {

		$self->notifier( Win32::ChangeNotify->new($entry, 1, DIR_NAME | FILE_NAME | LAST_WRITE ) );

		return 1;
	}

	return 0;
}

sub watcherDescriptor {
	my $self = shift;

	return $self->notifier->fileno;
}

1;

__END__
