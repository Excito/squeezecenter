package Slim::Web::Setup;

# $Id: Setup.pm 15258 2007-12-13 15:29:14Z mherger $

# SqueezeCenter Copyright 2001-2007 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

use strict;

use File::Spec::Functions qw(:ALL);
use Slim::Utils::Log;

sub initSetup {

	loadSettingsModules();
}

sub loadSettingsModules {

	my $base = catdir(qw(Slim Web Settings));

	# Pull in the settings modules. Lighter than Module::Pluggable, which
	# uses File::Find - and 2Mb of memory!
	for my $dir (@INC) {

		next if !-d catdir($dir, $base);

		for my $sub (qw(Player Server)) {

			opendir(DIR, catdir($dir, $base, $sub));

			while (my $file = readdir(DIR)) {

				next if $file !~ s/\.pm$//;

				my $class = join('::', splitdir($base), $sub, $file);

				eval "use $class";

				if (!$@) {

					$class->new;

				} else {

					logError ("can't load $class - $@");
				}
			}

			closedir(DIR);
		}

		last;
	}
}

1;

__END__
