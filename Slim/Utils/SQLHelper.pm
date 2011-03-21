package Slim::Utils::SQLHelper;

# $Id: SQLHelper.pm 10437 2006-10-22 00:24:04Z dsully $

=head1 NAME

Slim::Utils::SQLHelper

=head1 DESCRIPTION

Utility functions to handle reading of SQL files and executing them on the DB.

This may be replaced by DBIx::Class's deploy functionality.

=head1 METHODS

=head2 executeSQLFile( $driver, $dbh, $sqlFile )

Run the commands as specified in the sqlFile.

Valid commands are:

ALTER, CREATE, USE, SET, INSERT, UPDATE, DELETE, DROP, SELECT, OPTIMIZE,
TRUNCATE, UNLOCK, START, COMMIT

=head1 SEE ALSO

L<DBIx::Class>

L<DBIx::Migration>

=cut

use strict;
use File::Spec::Functions qw(:ALL);

use Slim::Utils::OSDetect;
use Slim::Utils::Log;

sub executeSQLFile {
	my $class  = shift;
	my $driver = shift;
	my $dbh    = shift;
	my $file   = shift;

	my $sqlFile = $file;

	if (!file_name_is_absolute($file)) {
		$sqlFile = catdir(Slim::Utils::OSDetect::dirsFor('SQL'), $driver, $file);
	}

	logger('database.sql')->info("Executing SQL file $sqlFile");

	open(my $fh, $sqlFile) or do {

		logError("Couldn't open file [$sqlFile] : $!");
		return 0;
	};

	my $statement   = '';
	my $inStatement = 0;

	for my $line (<$fh>) {
		chomp $line;

		# skip and strip comments & empty lines
		$line =~ s/\s*--.*?$//o;
		$line =~ s/^\s*//o;

		next if $line =~ /^--/;
		next if $line =~ /^\s*$/;

		if ($line =~ /^\s*(?:ALTER|CREATE|USE|SET|INSERT|UPDATE|DELETE|DROP|SELECT|OPTIMIZE|TRUNCATE|UNLOCK|START|COMMIT)\s+/oi) {
			$inStatement = 1;
		}

		if ($line =~ /;/ && $inStatement) {

			$statement .= $line;

			logger('database.sql')->info("Executing SQL: [$statement]");

			eval { $dbh->do($statement) };

			if ($@) {
				logError("Couldn't execute SQL statement: [$statement] : [$@]");
			}

			$statement   = '';
			$inStatement = 0;
			next;
		}

		$statement .= $line if $inStatement;
	}

	close $fh;

	return 1;
}

1;

__END__
