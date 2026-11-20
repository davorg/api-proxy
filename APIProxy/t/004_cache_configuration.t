use strict;
use warnings;

use Test::More;
use FindBin;
use File::Spec;
use CHI;
use Plack::Test;
use HTTP::Request::Common;
use HTTP::Response;
use LWP::UserAgent ();

# Load the checked-in configuration, even if the host points at another one.
# Do not replace the plugin settings as the isolated route test does.
local $ENV{DANCER_CONFDIR} = File::Spec->catdir($FindBin::Bin, '..');
local $ENV{GOOGLE_MAPS_API_KEY} = 'test-only-cache-key';
require APIProxy;
APIProxy::set(logger => 'null');

# CHI's own tests use this clock to check expiration without sleeping.
local $CHI::Driver::Test_Time = 1_700_000_000;
my $start_time = $CHI::Driver::Test_Time;
my $upstream_calls = 0;
my $key = 'gmap_search:q=Perl';

{
    no warnings 'redefine';
    local *LWP::UserAgent::request = sub {
        BAIL_OUT('Network access is disabled in the cache configuration test');
    };
    local *LWP::UserAgent::get = sub {
        ++$upstream_calls;
        return HTTP::Response->new(200, 'OK', [ 'Content-Type' => 'text/html' ],
            "<html><body>Fetch $upstream_calls</body></html>");
    };

    my $test = Plack::Test->create(APIProxy->to_app);
    my $cache = APIProxy::cache();
    isa_ok( $cache, 'CHI::Driver::Memory', 'Configured cache' );

    # A global Memory datastore with the same namespace must not leak into the
    # application's private cache or be changed by application writes.
    my $unrelated_cache = CHI->new(
        driver => 'Memory', global => 1, namespace => $cache->namespace,
    );
    $unrelated_cache->set($key, 'unrelated cache entry', 300);

    my $first = $test->request(GET '/gmap_search?q=Perl');
    is( $first->code, 200, 'Stock configuration serves a cache miss' );
    is( $first->content, '<html><body>Fetch 1</body></html>', 'First response is fresh' );
    is( $upstream_calls, 1, 'First request calls upstream once' );
    is( $unrelated_cache->get($key), 'unrelated cache entry', 'Global datastore is untouched' );

    my $object = $cache->get_object($key);
    ok( $object, 'Successful response is stored in the configured cache' );
    if ($object) {
        is( $object->expires_at - $object->created_at, 300, 'Entry has a 300-second TTL' );
    }

    my $second = $test->request(GET '/gmap_search?q=Perl');
    is( $second->code, 200, 'Stock configuration serves a cache hit' );
    is( $second->content, $first->content, 'Repeated request returns the same body' );
    is( $upstream_calls, 1, 'Immediate repeat does not call upstream' );

    $CHI::Driver::Test_Time = $start_time + 299;
    my $before_expiry = $test->request(GET '/gmap_search?q=Perl');
    is( $before_expiry->content, $first->content, 'Entry is still cached after 299 seconds' );
    is( $upstream_calls, 1, 'No upstream call before expiration' );

    $CHI::Driver::Test_Time = $start_time + 300;
    my $after_expiry = $test->request(GET '/gmap_search?q=Perl');
    is( $after_expiry->code, 200, 'Expired entry is refreshed successfully' );
    is( $after_expiry->content, '<html><body>Fetch 2</body></html>', 'Expired body is replaced' );
    is( $upstream_calls, 2, 'Only one additional upstream call after expiration' );
}

done_testing;
