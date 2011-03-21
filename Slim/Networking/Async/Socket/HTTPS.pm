package Slim::Networking::Async::Socket::HTTPS;

# $Id: HTTPS.pm 26931 2009-06-07 03:53:36Z michael $

# Squeezebox Server Copyright 2003-2009 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License, 
# version 2.

use strict;
use warnings;

BEGIN {
	# Force Net::HTTPS to use IO::Socket::SSL
	use IO::Socket::SSL;
}

use base qw(Net::HTTPS Slim::Networking::Async::Socket);

sub close {
	my $self = shift;

	# remove self from select loop
	Slim::Networking::Select::removeError($self);
	Slim::Networking::Select::removeRead($self);
	Slim::Networking::Select::removeWrite($self);
	Slim::Networking::Select::removeWriteNoBlockQ($self);

	$self->SUPER::close();
}

1;