import Foundation

/// Removes click-tracking parameters from URLs before they are ever requested.
///
/// This matters more than it looks. A blocked tracker script cannot see you, but
/// `?fbclid=…` travels *inside the URL of the page you actually want*, so the
/// destination site receives your cross-site identifier with no third-party
/// request involved. Content blocking cannot touch it; only rewriting can.
enum URLSanitizer {

    /// Parameters that are tracking identifiers on every host.
    private static let globalParameters: Set<String> = [
        // Google / analytics
        "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content",
        "utm_id", "utm_name", "utm_cid", "utm_reader", "utm_social", "utm_brand",
        "utm_pubreferrer", "utm_swu", "utm_viz_id", "ga_source", "ga_medium",
        "ga_term", "ga_content", "ga_campaign", "ga_place", "_ga", "_gl",
        "gclid", "gclsrc", "dclid", "wbraid", "gbraid", "gad_source", "gcl_au",
        // Microsoft / Yandex / others
        "msclkid", "yclid", "ysclid", "_openstat", "rb_clickid",
        // Meta
        "fbclid", "fb_action_ids", "fb_action_types", "fb_source", "fb_ref",
        // TikTok / Twitter / LinkedIn / Snap / Reddit
        "ttclid", "tt_medium", "tt_content",
        "twclid", "trk", "trkCampaign", "li_fat_id",
        "sc_cid", "scid", "rdt_cid",
        // Email marketing
        "mc_cid", "mc_eid", "mkt_tok", "vero_conv", "vero_id", "oly_anon_id",
        "oly_enc_id", "_hsenc", "_hsmi", "hsa_cam", "hsa_grp", "hsa_mt",
        "hsa_src", "hsa_ad", "hsa_acc", "hsa_net", "hsa_kw", "hsa_tgt", "hsa_ver",
        "ml_subscriber", "ml_subscriber_hash", "sb_referer_host",
        // Affiliate / commerce
        "irclickid", "irgwc", "ranMID", "ranEAID", "ranSiteID",
        "affiliate_id", "aff_id", "click_id", "cjevent",
        // Generic
        "igshid", "ig_rid", "epik", "pk_campaign", "pk_kwd", "pk_source",
        "piwik_campaign", "piwik_kwd", "matomo_campaign", "spm", "scm",
        "__twitter_impression", "guccounter", "guce_referrer", "guce_referrer_sig",
        "wt_mc", "wt_zmc", "cmpid", "ncid", "ito", "CMP", "cmp"
    ]

    /// Parameters that are tracking identifiers only on specific hosts. Removing
    /// these globally would break ordinary sites — `s` and `t` are far too common.
    private static let hostScopedParameters: [String: Set<String>] = [
        "twitter.com":   ["s", "t", "ref_src", "ref_url"],
        "x.com":         ["s", "t", "ref_src", "ref_url"],
        "youtube.com":   ["si", "pp", "feature", "kw"],
        "youtu.be":      ["si", "feature"],
        "amazon.com":    ["pd_rd_w", "pd_rd_r", "pd_rd_wg", "pf_rd_p", "pf_rd_r",
                          "pf_rd_s", "pf_rd_t", "pf_rd_i", "pf_rd_m", "_encoding",
                          "psc", "ref_", "th", "linkCode", "tag", "creativeASIN"],
        "reddit.com":    ["share_id", "utm_name", "correlation_id", "ref_campaign", "ref_source"],
        "instagram.com": ["igshid", "img_index"],
        "tiktok.com":    ["is_from_webapp", "sender_device", "web_id"],
        "spotify.com":   ["si", "nd"],
        "ebay.com":      ["_trkparms", "_trksid", "hash"],
        "aliexpress.com": ["spm", "algo_pvid", "algo_exp_id", "pdp_ext_f", "gatewayAdapt"],
        "bing.com":      ["form", "cvid", "pq", "qs", "sk", "sc"],
        "medium.com":    ["source"],
        "linkedin.com":  ["refId", "trackingId", "lipi", "licu", "midToken", "midSig"]
    ]

    struct Result: Equatable {
        var url: URL
        var removed: [String]
        var didChange: Bool { !removed.isEmpty }
    }

    static func sanitize(_ url: URL) -> Result {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems, !items.isEmpty
        else { return Result(url: url, removed: []) }

        var scoped: Set<String> = []
        if let domain = PublicSuffix.registrableDomain(of: url) {
            scoped = hostScopedParameters[domain] ?? []
        }

        var removed: [String] = []
        let kept = items.filter { item in
            let name = item.name
            let isTracking = globalParameters.contains(name)
                || scoped.contains(name)
                || globalParameters.contains(name.lowercased())
            if isTracking { removed.append(name) }
            return !isTracking
        }

        guard !removed.isEmpty else { return Result(url: url, removed: []) }
        components.queryItems = kept.isEmpty ? nil : kept
        // An empty query must drop the `?` too, or the URL keeps changing shape
        // on every pass and the navigation delegate loops.
        if kept.isEmpty { components.query = nil }

        return Result(url: components.url ?? url, removed: removed)
    }

    /// Sanitising must be idempotent, otherwise the navigation delegate that
    /// cancels-and-reloads on a change would spin forever.
    static func isClean(_ url: URL) -> Bool { !sanitize(url).didChange }
}
