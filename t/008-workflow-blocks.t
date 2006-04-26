#!/usr/bin/perl

use strict;
use warnings;
use Test::More tests => 38;

require "t/rtir-test.pl";

my $agent = default_agent();

my $inc_id   = create_incident($agent, {Subject => "incident with block"});
my $block_id = create_block($agent, {Subject => "block", Incident => $inc_id});

display_ticket($agent, $block_id);
ok_and_content_like($agent, qr{State.*?pending activation}, 'checked state of the new block');

# XXX: Comment this tests as we don't allow to create blocks without an incident
# XXX: we need test for this fact
#$agent->follow_link_ok({ text => "[Link]" }, "Followed '[Link]' link");
#$agent->form_number(2);
#$agent->field('SelectedTicket', $inc_id);
#$agent->click('LinkChild');
#ok_and_content_like($agent, qr{$block_id.*block.*?pending activation}, 'have child link');
#
#$agent->follow_link_ok({ text => $block_id }, "Followed link back to block");
#ok_and_content_like($agent, qr{State.*?pending activation}, 'checked state of the new block');

$agent->has_tag('a', 'Remove', 'we have Remove action');
$agent->has_tag('a', 'Quick Remove', 'we have Quick Remove action');

my %state = (
    new      => 'pending activation',
    open     => 'active',
    stalled  => 'pending removal',
    resolved => 'removed',
    rejected => 'removed',
);

foreach my $status( qw(open stalled resolved) ) {
    $agent->follow_link_ok({ text => "Edit" }, "Goto edit page");
    $agent->form_number(2);
    $agent->field(Status => $status);
    $agent->click('SaveChanges');
    my $state = $state{ $status };
    ok_and_content_like($agent, qr{State.*?\Q$state}, 'changed state block');
}


$agent->follow_link_ok({ text => "Edit" }, "Goto edit page");
$agent->form_number(2);
$agent->field(Status => 'resolved');
$agent->click('SaveChanges');
ok_and_content_like($agent, qr{State.*?removed}, 'changed state block');
$agent->has_tag('a', 'Activate', 'we have Activate action');

$agent->follow_link_ok({ text => 'Activate' }, "Reactivate block");
ok_and_content_like($agent, qr{State.*?active}, 'checked state of the block');
$agent->has_tag('a', 'Pending Removal', 'we have Pending Removal action tab');

$agent->follow_link_ok({ text => 'Pending Removal' }, "Prepare block for remove");
$agent->form_number(2);
$agent->click('SubmitTicket');
ok_and_content_like($agent, qr{State.*?pending removal}, 'checked state of the block');



