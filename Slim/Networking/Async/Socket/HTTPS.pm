package Slim::Networking::Async::Socket::HTTPS;

# $Id: HTTPS.pm 15258 2007-12-13 15:29:14Z mherger $

# SqueezeCenter Copyright 2003-2007 Logitech.
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