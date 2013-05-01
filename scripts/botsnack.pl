use warnings;
use strict;
use Irssi;
use Data::Dumper;

my %responses = (
	message => sub {
		my ($text, $nick) = @_; $_ = $text; undef;
		
		if (/^botsnack$/) {
			(":D") x 3,
			"humansnack",
			"/me chews on $nick."
		} elsif (/^U\+(\x{4})$/) {
			pack("U", hex $1)
#		} elsif (/^(\w+) .+ is \g{1}\W*$/i) {
#			"Redundant adjective is redundant.",
#			(undef) x 10,
		} elsif (/^nanobot owns\W*$/i) {
			"Aye, I do."
		} elsif (/^what the duck/i) {
			"quack"
		} elsif (/^what happen\W*$/i) {
			"Somebody set up us the bomb."
		}
	},
	action => sub {
		my ($text, $nick) = @_; $_ = $text; undef;

		if (/^(press|push)es ((a|the) )?button/) {
			"[A nuke is launched at Bash.]",
			"/me dispenses bacon",
			"/me dispenses a cheeseburger",
			"Please don't press the button again.",
			"[A buzzing noise is heard.]",
			"/me takes off every 'ZIG'",
		} elsif (/^looks around$/) {
			"It is pitch black. You are likely to be eaten by a grue.",
			(undef) x 5,
		}
	},
);

sub on_event {
	my ($type, $server, $text, $nick, $addr, $target) = @_;
	my @replies = $responses{$type}->($text, $nick);
	return unless @replies and $replies[0];
	my $reply = $replies[rand @replies];
	return unless defined $reply;
	if ($reply =~ m!^/me (.*)$!) {
		$server->command("action $target $1")
	} else {
		$server->command("msg $target $reply")
	}
}

Irssi::signal_add "message irc action", sub {
	on_event "action", @_;
};
Irssi::signal_add "message public", sub {
	on_event "message", @_;
};
