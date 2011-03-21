package Slim::Utils::OS::Suse;

# Squeezebox Server Copyright 2001-2009 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License, 
# version 2.

use strict;
use base qw(Slim::Utils::OS::RedHat);

sub initDetails {
	my $class = shift;

	$class->{osDetails} = $class->SUPER::initDetails();

	$class->{osDetails}->{isSuse} = 1;
	
	delete $class->{osDetails}->{isRedHat} if defined $class->{osDetails}->{isRedHat};

	return $class->{osDetails};
}

1;