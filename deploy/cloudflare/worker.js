// Serves install.sh at cdev.pimlabs.id, so the documented command is short
// and stable while the script itself stays a release asset in the public
// repo. Replaces a plain Cloudflare redirect to
// https://github.com/pimlabs/cdev/releases/latest/download/install.sh.
//
// This is a route rather than a Custom Domain: it claims only the two paths
// below and everything else on that hostname reaches whatever origin was
// already there. See wrangler.toml.
//
// Why a Worker instead of a redirect rule, since a redirect needs no code:
//
//   - A redirect that the client does not follow fails silently. Measured on
//     the redirect this replaces: `curl -fsS https://cdev.pimlabs.id/install`
//     returns HTTP 301, a 167-byte HTML body, and exit code 0, since `-f`
//     only catches 4xx and 5xx. `curl -fsS ... | bash` runs bash on that HTML
//     instead of the script and says nothing useful about why.
//   - GitHub is reached by Cloudflare's edge rather than by the user's
//     machine, which still works on networks that block
//     raw.githubusercontent.com.
//   - An upstream failure can be answered with a sentence (502 below) rather
//     than with an empty pipe.
//
// Speed was never the argument and does not survive measurement: from a
// laptop in Singapore, raw.githubusercontent.com answered in 130-180ms
// against 340-780ms for a comparable Cloudflare-served script.
//
// cdev's own release model is NOT the same as the pattern this file is
// adapted from (agentop's Worker, which serves install.sh straight off
// `main`): cdev's install.sh must resolve to a tagged release, never to a
// branch, since piping a moving branch into a shell with sudo access is a
// far bigger ask than piping a fixed one (see ROADMAP.md, "Distribution:
// one-line install"). So instead of a fixed ref, this Worker resolves
// GitHub's own `/releases/latest` redirect to find the newest tag, the same
// thing `_cdev-latest-tag` in cdev.sh and `cdev_latest_tag` in install.sh
// already do, and the same reason they give for doing it this way:
// deliberately not the GitHub API, no JSON to parse and no unauthenticated
// rate limit to hit, which matters more here than in a shell script since
// Cloudflare's edge IPs are shared across far more callers than one box's
// own IP ever would be.
//
// cdev only ever publishes one tag series (`vX.Y.Z` for the tool itself, no
// separate extension or companion product sharing the releases page), so
// `/releases/latest` answering with "the newest release of any kind" is not
// a trap here the way it was for a sibling project with two tag series on
// one page. Still validated below against the same tag glob `cdev doctor`
// already trusts, so a future non-`vX.Y.Z` release on this repo fails loudly
// instead of silently serving whatever GitHub redirected to.

const REPO = "pimlabs/cdev";

const ROUTES = {
  "/install": "install.sh",
  "/install.sh": "install.sh",
};

// What bun, pnpm, starship and poetry all send on their install endpoints,
// read off their responses rather than chosen: never serve a stale install
// script, always revalidate. Paired with the ETag below, a revalidation is a
// 304 rather than a re-download.
//
// Deliberately no `cf: { cacheTtl }` on the upstream fetch either. At this
// project's traffic an edge cache saves nothing measurable and buys a window
// where a just-tagged script is not yet the one people get.
const CACHE_CONTROL = "public, max-age=0, must-revalidate";

const TAG_RE = /^v\d+\.\d+\.\d+$/;

const text = (body, status) =>
  new Response(body, {
    status,
    headers: {
      "content-type": "text/plain; charset=utf-8",
      "cache-control": CACHE_CONTROL,
    },
  });

// Same redirect-following approach as `_cdev-latest-tag`/`cdev_latest_tag`:
// GitHub answers /releases/latest with a redirect to /releases/tag/<tag>,
// read here from the Location header instead of the JSON API.
async function resolveLatestTag() {
  const res = await fetch(`https://github.com/${REPO}/releases/latest`, {
    redirect: "manual",
  });
  const location = res.headers.get("location");
  const match = location?.match(/\/releases\/tag\/([^/?#]+)$/);
  const tag = match?.[1];
  if (!tag || !TAG_RE.test(tag)) return null;
  return tag;
}

export default {
  async fetch(request) {
    const url = new URL(request.url);
    const file = ROUTES[url.pathname];
    if (!file) {
      return text("not found\n", 404);
    }
    if (request.method !== "GET" && request.method !== "HEAD") {
      return text("method not allowed\n", 405);
    }

    // /install?ref=v0.9.0 installs a specific past release instead of the
    // latest one, without a second route and without a second copy of the
    // script anywhere. No ref means resolve the latest tag, never `main`.
    //
    // ref is restricted to the same vX.Y.Z tag shape as the resolved-latest
    // path, not an arbitrary branch/ref like agentop's Worker allows: cdev's
    // own install URL must always resolve to a tagged release (see the
    // comment above REPO), and a looser charset here (agentop's allows `.`
    // and `/`) would let `ref=../../other/repo/main` escape the intended
    // path segment of the raw.githubusercontent.com URL below and turn this
    // Worker into an open proxy for arbitrary public repo content.
    const refParam = url.searchParams.get("ref");
    let ref;
    if (refParam) {
      if (!TAG_RE.test(refParam)) {
        return text("bad ref, expected a tag like v0.9.0\n", 400);
      }
      ref = refParam;
    } else {
      ref = await resolveLatestTag();
      if (!ref) {
        return text(
          `cdev: could not resolve the latest release tag for ${REPO}.\n` +
            `Try again, or install a specific version with ?ref=vX.Y.Z, or ` +
            `see https://github.com/${REPO}/releases\n`,
          502,
        );
      }
    }

    const upstream = `https://raw.githubusercontent.com/${REPO}/${ref}/${file}`;

    // The client's validator is forwarded so GitHub can answer 304, and
    // GitHub's is forwarded back so the client can ask again next time.
    const ifNoneMatch = request.headers.get("if-none-match");
    const res = await fetch(upstream, {
      headers: ifNoneMatch ? { "if-none-match": ifNoneMatch } : {},
    });

    if (res.status === 304) {
      const headers = { "cache-control": CACHE_CONTROL };
      const etag = res.headers.get("etag");
      if (etag) headers.etag = etag;
      return new Response(null, { status: 304, headers });
    }

    if (!res.ok) {
      // The thing a redirect cannot do: fail out loud. Piping this into
      // bash prints the line instead of doing nothing.
      return text(
        `cdev: could not fetch ${file} for ${ref} from GitHub (HTTP ${res.status}).\n` +
          `Try again, or install from https://github.com/${REPO}/releases\n`,
        502,
      );
    }

    const headers = {
      "content-type": "text/x-sh; charset=utf-8",
      "cache-control": CACHE_CONTROL,
      "x-content-type-options": "nosniff",
    };
    const etag = res.headers.get("etag");
    if (etag) headers.etag = etag;

    return new Response(res.body, { headers });
  },
};
