#!perl
use warnings;
use strict;
use feature 'switch';

use Irssi;
use Data::Dumper;

our @allowed = qw(
	nathan*!nathan@nathan7.eu
	nathan*!*nathan@zoo.nathan7.eu
	*!nathan@69.61.15.114
	nathan!*nathan@raja.xs4all.nl

	grawity!*@78-60-211-195.static.zebra.lt
	grawity!*grawity@*.nullroute.eu.org
	grawity!*grawity@grawity.vpn.cluenet.org
	grawity!grawity@*.cluenet.org
	grawity!grawity@192.168.151.102
	grawity!grawity@*.nathan7.eu

	fahadsadah!fahad@equal.cluenet.org
);

#Irssi::theme_register([
#	eval_code => '{hilight 

sub allowed {
	my ($server, $nick, $addr) = @_;
	return $server->masks_match(join(" ", @allowed), $nick, $addr);
}

sub do_eval {
	my ($server, $text, $nick, $addr, $target) = @_;
	my $me = $server->{nick};
	return unless $text =~ s/^\Q${me}\E[:,] //;
	return unless allowed($server, $nick, $addr);
	my $level = MSGLEVEL_WALLOPS;
	if ($text =~ /^eval (.+)$/) {
		$text = $1;
		my $text_esc = $text;
		$text_esc =~ s/%/%%/g;
		Irssi::print("Eval: !$nick! $text_esc", $level);
		my $d = Data::Dumper->new([eval $text]);
		if ($@) {
			$server->command("msg $target $nick: Error: $@");
		} else {
			$d->Indent(0);
			$d->Terse(1);
			my $out = $d->Dump;
			$server->command("msg $target $nick: $out");
		}
	} elsif ($text =~ /^\//) {
		Irssi::print("Cmd: !$nick! $text", $level);
		$server->command("$text");
	} elsif ($text =~ /update/) {
		given (`~/bin/update`) {
			when (/^noop$/) {
				$server->command("msg $target $nick: already up-to-date");
			}
			when (/^ok (\w{5})\w+$/) {
				$server->command("msg $target $nick: updated to $1");
				Irssi::command("script load nbot.pl");
			}
			when (/^err (\d+)$/) {
				$server->command("msg $target $nick: $_");
			}
		}
	}
}
Irssi::signal_add "message public" => \&do_eval;
Irssi::signal_add "message private" => \&do_eval;
