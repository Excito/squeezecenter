package Slim::Networking::Async::Socket;

# $Id: Socket.pm 26931 2009-06-07 03:53:36Z michael $

# Squeezebox Server Copyright 2003-2009 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License, 
# version 2.

# A base class for all sockets

use strict;
use warnings;

# store data within the socket
sub set {
	my ( $self, $key, $val ) = @_;
	
	${*$self}{$key} = $val;
}

# pull data out of the socket
sub get {
	my ( $self, $key ) = @_;
	
	return ${*$self}{$key};
}

1;