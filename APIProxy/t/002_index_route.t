use strict;
use warnings;

use APIProxy;
use Test::More tests => 5;
use Plack::Test;
use HTTP::Request::Common;
use Ref::Util qw<is_coderef>;

my $app = APIProxy->to_app;
ok( is_coderef($app), 'Got app' );

my $test = Plack::Test->create($app);
my $res  = $test->request( GET '/' );

ok( $res->is_success, '[GET /] successful' );
like( $res->content, qr/<title>API Proxy<\/title>/, 'Template title is rendered' );
like( $res->content, qr/Dave's API Proxy/, 'Index content is rendered in the layout' );
unlike( $res->content, qr/<%/, 'No unexpanded template expressions' );
