vcl 4.0;

backend default {
	.host = "127.0.0.1";
	.port = "8080";
}

import std;

#include "lib/xforward.vcl"; # Varnish 4.0: X-Forwarded-For is now set before vcl_recv
include "lib/cloudflare.vcl";
include "lib/purge.vcl";
include "lib/bigfiles.vcl";        # Varnish 3.0.3+
#include "lib/bigfiles_pipe.vcl";  # Varnish 3.0.2
include "lib/static.vcl";

acl cloudflare {
	# set this ip to your Railgun IP (if applicable)
	# "1.2.3.4";
}

acl purge {
	"localhost";
	"127.0.0.1";
}

# Pick just one of the following:
# (or don't use either of these if your application is "adaptive")
# include "lib/mobile_cache.vcl";
# include "lib/mobile_pass.vcl";

### WordPress-specific config ###
# This config was initially derived from the work of Donncha Ó Caoimh:
# http://ocaoimh.ie/2011/08/09/speed-up-wordpress-with-apache-and-varnish/
sub vcl_recv {
	# pipe on weird http methods
	if (req.method !~ "^GET|HEAD|PUT|POST|TRACE|OPTIONS|DELETE$") {
		return(pipe);
	}

	### Check for reasons to bypass the cache!
	# never cache anything except GET/HEAD
	if (req.method != "GET" && req.method != "HEAD") {
		return(pass);
	}
	# don't cache logged-in users or authors
	if (req.http.Cookie ~ "wp-postpass_|wordpress_logged_in_|comment_author|PHPSESSID") {
		return(pass);
  } else {
    unset req.http.cookie;
  }
	# don't cache ajax requests
	if (req.http.X-Requested-With == "XMLHttpRequest") {
		return(pass);
	}
	# don't cache these special pages
	if (req.url ~ "nocache|wp-admin|wp-(comments-post|login|activate|mail)\.php|bb-admin|server-status|control\.php|bb-login\.php|bb-reset-password\.php|register\.php") {
		return(pass);
	}

	# Normalize Accept-Encoding header and compression
	# https://www.varnish-cache.org/docs/3.0/tutorial/vary.html
	if (req.http.Accept-Encoding) {
		# Do not compress compressed files...
		if (req.url ~ "\.(jpg|png|gif|gz|tgz|bz2|tbz|mp3|ogg)$") {
				unset req.http.Accept-Encoding;
		} elsif (req.http.Accept-Encoding ~ "gzip") {
				set req.http.Accept-Encoding = "gzip";
		} elsif (req.http.Accept-Encoding ~ "deflate") {
				set req.http.Accept-Encoding = "deflate";
		} else {
			unset req.http.Accept-Encoding;
		}
	}


	### looks like we might actually cache it!
	# fix up the request
	set req.url = regsub(req.url, "\?replytocom=.*$", "");


	return(hash);
}

sub vcl_hash {
	# Add the browser cookie only if a WordPress cookie found.
	if (req.http.Cookie ~ "wp-postpass_|wordpress_logged_in_|comment_author|PHPSESSID") {
		hash_data(req.http.Cookie);
	}

	# If the client supports compression, keep that in a different cache
	if (req.http.Accept-Encoding) {
		hash_data(req.http.Accept-Encoding);
	}
}

sub vcl_backend_response {
	# make sure grace is at least 2 minutes
	if (beresp.grace < 2m) {
		set beresp.grace = 2m;
	}

	# catch obvious reasons we can't cache
	if (beresp.http.Set-Cookie) {
		set beresp.ttl = 0s;
	}

	# Varnish determined the object was not cacheable
	if (beresp.ttl <= 0s) {
		set beresp.http.X-Cacheable = "NO:Not Cacheable";
		set beresp.uncacheable = true;
		return (deliver);

	# You don't wish to cache content for logged in users
	} else if (bereq.http.Cookie ~ "wp-postpass_|wordpress_logged_in_|comment_author|PHPSESSID") {
		set beresp.http.X-Cacheable = "NO:Got Session";
		set beresp.uncacheable = true;
		return (deliver);

	# You are respecting the Cache-Control=private header from the backend
	} else if (beresp.http.Cache-Control ~ "private") {
		set beresp.http.X-Cacheable = "NO:Cache-Control=private";
		set beresp.uncacheable = true;
		return (deliver);

	# You are extending the lifetime of the object artificially
	} else if (beresp.ttl < 300s) {
		set beresp.ttl   = 300s;
		set beresp.grace = 300s;
		set beresp.http.X-Cacheable = "YES:Forced";

	# Varnish determined the object was cacheable
	} else {
		set beresp.http.X-Cacheable = "YES";
	}

	# Avoid caching error responses
	if (beresp.status == 404 || beresp.status >= 500) {
		set beresp.ttl   = 0s;
		set beresp.grace = 15s;
	}

	# Deliver the content
	return(deliver);
}

# The routine when we deliver the HTTP request to the user
# Last chance to modify headers that are sent to the client
sub vcl_deliver {
	if (obj.hits > 0) { 
		set resp.http.X-Cache = "HIT";
	} else {
		set resp.http.X-Cache = "MISS";
	}

	# Remove some headers: PHP version
	unset resp.http.X-Powered-By;

	# Remove some headers: Version & OS
	unset resp.http.Server;

	# Remove some heanders: Varnish
	unset resp.http.Via;
	unset resp.http.X-Varnish;

	return (deliver);
}
