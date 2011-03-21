package Slim::Schema::Year;

# $Id: Year.pm 18637 2008-04-10 02:11:54Z andy $

use strict;
use base 'Slim::Schema::DBI';

use Slim::Utils::Misc;
use Slim::Utils::Strings qw(string);

{
	my $class = __PACKAGE__;

	# Magic to create a ResultSource for this inherited class.
	$class->table('years');

	$class->add_columns('id');
	$class->set_primary_key('id');

	$class->has_many('album' => 'Slim::Schema::Album' => 'year');
	$class->has_many('tracks' => 'Slim::Schema::Track' => 'year');

	$class->resultset_class('Slim::Schema::ResultSet::Year');
}

# For saving favorites
sub url {
	my $self = shift;

	return sprintf('db:year.id=%s', Slim::Utils::Misc::escape($self->id));
}

sub name {
	my $self = shift;

	return $self->id || string('UNK');
}

sub namesort {
	my $self = shift;

	return $self->name;
}

sub displayAsHTML {
	my ($self, $form, $descend, $sort) = @_;

	$form->{'text'} = $self->name;

	my $Imports = Slim::Music::Import->importers;

	for my $mixer (keys %{$Imports}) {

		if (defined $Imports->{$mixer}->{'mixerlink'}) {
			&{$Imports->{$mixer}->{'mixerlink'}}($self, $form, $descend); 	 
		}
	}
}

# Cleanup years that are no longer used by albums or tracks
sub cleanupStaleYears {
	my $class = shift;
	
	Slim::Schema->storage->dbh->do( qq{
		DELETE years y
		FROM   years y
		LEFT JOIN (
			SELECT DISTINCT year FROM albums a
			UNION
			SELECT DISTINCT year FROM tracks t
		) z 
		ON     y.id = z.year
		WHERE  z.year is NULL
	} );
}

1;

__END__
