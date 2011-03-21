package Slim::Utils::Scheduler;

# $Id: Scheduler.pm 27975 2009-08-01 03:28:30Z andy $
#
# Squeezebox Server Copyright 2001-2009 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License, 
# version 2.


=head1 NAME

Slim::Utils::Scheduler

=head1 SYNOPSIS

Slim::Utils::Scheduler::add_task(\&scanFunction);

Slim::Utils::Scheduler::remove_task(\&scanFunction);

=head1 DESCRIPTION

 This module implements a simple scheduler for cooperative multitasking 

 If you need to do something that will run for more than a few milliseconds,
 write it as a function which works on the task incrementally, returning 1 when
 it has more work to do, 0 when finished.

 Then add it to the list of background tasks using add_task, giving a pointer to
 your function and a list of arguments. 

 Background tasks should be run whenever the server has extra time on its hands, ie,
 when we'd otherwise be sitting in select.

=cut

use strict;

use Slim::Utils::Log;
use Slim::Utils::Misc;

my $curtask = 0;            # the next task to run
my @background_tasks = ();  # circular list of references to arrays (sub ptrs with args)
my $lastpass = 0;

my $log = logger('server.scheduler');

use constant BLOCK_LIMIT => 0.01; # how long we are allowed to block the server

=head1 METHODS

=head2 add_task( @task)

 Add a new task to the scheduler. Takes an array for task identifier.  First element is a 
 code reference to the sheduled subroutine.  Subsequent elements are the args required by 
 the newly scheduled task.

=cut

sub add_task {
	my @task = @_;

	main::INFOLOG && $log->is_info && $log->info("Adding task: @task");

	push @background_tasks, \@task;
}

=head2 remove_task( $taskref, [ @taskargs ])

 Remove a task from teh scheduler.  The first argument is the 
 reference to the scheduled function
 
 Optionally, the arguments required when starting the scheduled task are
 included for identifying the correct task.

=cut

sub remove_task {
	my ($taskref, @taskargs) = @_;
	
	my $i = 0;

	while ($i < scalar (@background_tasks)) {

		my ($subref, @subargs) = @{$background_tasks[$i]};

		if ($taskref eq $subref) {

			main::INFOLOG && $log->is_info && $log->info("Removing taskptr $i: $taskref");

			splice @background_tasks, $i, 1; 
		}

		$i++;
	}

	# loop around when we get to the end of the list
	if ($curtask >= (@background_tasks)) {
		$curtask = 0;
	}			
}


=head2 run_tasks( )

 run one background task
 returns 0 if there is nothing to run

=cut

sub run_tasks {
	return 0 unless @background_tasks;
	
	# Don't recurse more than 10 times
	my $count = shift || 1;
	return 1 if $count > 10;
	
	my $busy  = 0;
	my $now   = AnyEvent->now;
	
	# run tasks at least once half second.
	if (($now - $lastpass) < 0.5) {

		for my $client (Slim::Player::Client::clients()) {

			if (Slim::Player::Source::playmode($client) eq 'play' && 
			    $client->isPlayer() && 
			    $client->usage() < 0.5) {

				$busy = 1;
				last;
			}
		}
	}
	
	if (!$busy) {
		my $taskptr = $background_tasks[$curtask];
		my ($subptr, @subargs) = @$taskptr;

		my $cont = eval { &$subptr(@subargs) };

		if ($@) {
			logError("Scheduled task failed: $@");
		}

		if ($@ || !$cont) {

			# the task has finished. Remove it from the list.
			main::INFOLOG && $log->is_info && $log->info("Task finished: $subptr");

			splice(@background_tasks, $curtask, 1);

		} else {

			$curtask++;
		}

		$lastpass = $now;

		# loop around when we get to the end of the list
		if ($curtask >= scalar @background_tasks) {
			$curtask = 0;
		}

		main::PERFMON && Slim::Utils::PerfMon->check('scheduler', AnyEvent->time - $now, undef, $subptr);
	}
	
	# Run again if we haven't yet reached the blocking limit
	# Note $now will remain the same across multiple calls
	if ( @background_tasks && ( AnyEvent->time - $now < BLOCK_LIMIT ) ) {
		run_tasks( ++$count );
		main::idleStreams();
	}

	return 1;
}

1;
