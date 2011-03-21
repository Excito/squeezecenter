package Slim::Utils::Errno;

# $Id: Errno.pm 15258 2007-12-13 15:29:14Z mherger $

# SqueezeCenter Copyright 2001-2007 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License, 
# version 2.

=head1 NAME

Slim::Utils::Errno

=head1 DESCRIPTION

Platform correct error constants.

=head1 EXPORTS

=over 4

=item * EWOULDBLOCK

=item * EINPROGRESS

=item * EINTR

=item * ECHILD

=back

=cut

use strict;
use Exporter::Lite;

our @EXPORT = qw(EWOULDBLOCK EINPROGRESS EINTR ECHILD);

BEGIN {
        if ($^O =~ /Win32/) {
                *EINTR       = sub () { 10004 };
                *ECHILD      = sub () { 10010 };
                *EWOULDBLOCK = sub () { 10035 };
                *EINPROGRESS = sub () { 10036 };
        } else {
                require Errno;
                import Errno qw(EWOULDBLOCK EINPROGRESS EINTR ECHILD);
        }
}

=head1 SEE ALSO

L<Errno>

=cut

1;

__END__
