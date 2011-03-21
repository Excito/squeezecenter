package Slim::Plugin::Base;

# $Id: Base.pm 21788 2008-07-15 20:01:58Z andy $

# Base class for plugins. Implement some basics.

use strict;
use Slim::Buttons::Home;
use Slim::Utils::Log;

use constant PLUGINMENU => 'PLUGINS';

sub initPlugin {
	my $class = shift;
	my $args  = shift;

	my $name  = $class->displayName;
	my $menu  = $class->playerMenu;
	my $mode  = $class->modeName;

	# This is a bit of a hack, but since Slim::Buttons::Common is such a
	# disaster, and has no concept of OO, we need to wrap 'setMode' (an
	# ambiguous function name if there ever was) in a closure so that it
	# can be called as class method.
	if ($class->can('setMode')) {

		my $exitMode = $class->can('exitMode') ? sub { $class->exitMode(@_) } : undef;

		Slim::Buttons::Common::addMode($mode, $class->getFunctions, sub { $class->setMode(@_) }, $exitMode);

		my %params = (
			'useMode'   => $mode,
			'header'    => $name,
			'condition' => sub { $class->condition(shift); },
		);

		# Add toplevel info for the option of having a plugin at the top level.
		Slim::Buttons::Home::addMenuOption($name, \%params);

		Slim::Buttons::Home::addSubMenu($menu, $name, \%params);

		# Add new submenus to Extras but only if they aren't main top-level menus
		my $topLevel = {
			HOME           => 1,
			BROWSE_MUSIC   => 1,
			RADIO          => 1,
			MUSIC_SERVICES => 1,
			SETTINGS       => 1,
		};
		
		if ( $menu ne PLUGINMENU && !$topLevel->{$menu} ) {

			Slim::Buttons::Home::addSubMenu(PLUGINMENU, $menu, Slim::Buttons::Home::getMenu("-$menu"));
		}
	}

	if ( !main::SLIM_SERVICE ) {
		if ($class->can('webPages')) {

			$class->webPages;
		}
		
		if ($class->_pluginDataFor('icon')) {
			Slim::Web::Pages->addPageLinks("icons", { $name => $class->_pluginDataFor('icon') });
		}
	}

	if ($class->can('defaultMap')) {

		Slim::Hardware::IR::addModeDefaultMapping($mode, $class->defaultMap);
	}
}

sub displayName {
	my $class = shift;

	return $class->_pluginDataFor('name') || $class;
}

sub playerMenu {
	my $class = shift;

	return $class->_pluginDataFor('playerMenu') || PLUGINMENU;
}

sub modeName {
	my $class = shift;

	return $class;
}

sub condition {
	return 1;
}

sub _pluginDataFor {
	my $class = shift;
	my $key   = shift;

	my $pluginData = Slim::Utils::PluginManager->dataForPlugin($class);

	if ($pluginData && ref($pluginData) && $pluginData->{$key}) {
		
		# Bug 7110, on SN provide a full path for icons
		if ( main::SLIM_SERVICE && $key eq 'icon' ) {
			use Slim::Networking::SqueezeNetwork;			
			return Slim::Networking::SqueezeNetwork->url( '/static/jive/' . $pluginData->{$key}, 1 );
		}

		return $pluginData->{$key};
	}

	return undef;
}

sub getFunctions {
	my $class = shift;

	return {};
}

1;

__END__
