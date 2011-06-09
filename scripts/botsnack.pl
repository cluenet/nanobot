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
#		} elsif (/^(\w+) .+ is \g{1}\W*$/i) {
#			(undef) x 10,
#			"Redundant adjective is redundant.",
#			"Overused meme is overused."
		} elsif (/^nanobot owns\W*$/i) {
			"Aye, I do."
		} elsif (/^what the duck/i) {
			"quack"
		}
	},
	action => sub {
		my ($text, $nick) = @_; $_ = $text; undef;

		#if (/^(press|push)es ((a|the) )?button/) {
		#	"[A nuke is launched at Bash.]",
		#	"/me dispenses bacon",
		#	"/me dispenses a cheeseburger",
		#	"Please don't press the button again.",
		#	"[A buzzing noise is heard.]"
		#}
	},
);

sub on_event {
	my ($type, $server, $text, $nick, $addr, $target) = @_;
	my @replies = $responses{$type}->($text, $nick);
	return unless @replies and $replies[0];
	my $reply = $replies[rand @replies];
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
