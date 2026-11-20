# frozen_string_literal: true

require 'base64'

# Uno Dos Cloud fork — ERP (Malibu) iframe SSO hand-off.
#
# The ERP shell (erp.tripwave.cloud) embeds this Chatwoot in an iframe. Instead
# of running an OIDC round-trip inside the frame (Authentik refuses to be
# framed), the ERP backend mints a short-lived HMAC ticket and points the
# iframe at GET /erp/sso?ticket=…. This controller verifies the ticket and
# finishes the login through Chatwoot's own `sso_auth_token` mechanism, so the
# SPA session is established exactly like the regular OIDC flow.
#
# Contract (must stay in sync with apps/api-gateway/src/integrations/integrations.service.ts):
#   ticket  = "v1.<base64url(json)>.<hex hmac_sha256>"
#   hmac    = HMAC_SHA256(secret, "v1.<base64url(json)>")
#   payload = { sub, email, name, avatarUrl, acc, conv, loc, jti, iat, exp }
#
# The whole feature is env-gated: without CHATWOOT_ERP_SSO_SECRET the endpoint
# answers 404, so a stock deployment stays stock.
module Custom
  class ErpSsoController < ActionController::Base
    TICKET_VERSION = 'v1'
    TICKET_TTL_SECONDS = 60
    CLOCK_SKEW_SECONDS = 10

    # Embed presentation flags forwarded from the ERP iframe URL. They are
    # sanitised here so the redirect can only carry known values.
    EMBED_PARAMS = {
      'erp_embed' => %w[0 1],
      'erp_theme' => %w[dark light]
    }.freeze

    # GET /erp/sso?ticket=…
    def show
      # Feature is off unless the ERP shared secret is configured: answer 404
      # so a stock deployment looks untouched (no route fingerprint).
      return head :not_found if secret.blank?

      payload = verified_payload(params[:ticket].to_s)
      return head :unauthorized if payload.nil?
      return head :unauthorized unless consume_ticket(payload)

      @resource = Custom::OidcUserBuilder.new(auth_hash_from(payload)).perform
      return redirect_to(login_error_url('erp-sso-no-account')) unless @resource&.persisted?

      redirect_to login_url_for(@resource, payload), allow_other_host: true
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
      Rails.logger.warn("[erp-sso] provisioning failed: #{e.class}: #{e.message}")
      redirect_to login_error_url('erp-sso-provisioning-failed'), allow_other_host: true
    end

    private

    def secret
      ENV.fetch('CHATWOOT_ERP_SSO_SECRET', nil)
    end

    # Returns the parsed payload only for a well-formed, correctly signed and
    # unexpired ticket. Any deviation yields nil (single generic 401 response:
    # no oracle for forged vs expired vs malformed).
    def verified_payload(ticket)
      version, body, signature = ticket.split('.')
      return nil unless version == TICKET_VERSION && body.present? && signature.present?

      signing_input = "#{version}.#{body}"
      expected = OpenSSL::HMAC.hexdigest('SHA256', secret, signing_input)
      return nil unless ActiveSupport::SecurityUtils.secure_compare(expected, signature)

      payload = JSON.parse(Base64.urlsafe_decode64(body))
      return nil unless payload.is_a?(Hash)
      return nil unless payload['email'].present? && payload['jti'].present?

      now = Time.current.to_i
      exp = payload['exp'].to_i
      iat = payload['iat'].to_i
      return nil if exp <= now
      return nil if exp - iat > TICKET_TTL_SECONDS + CLOCK_SKEW_SECONDS
      return nil if iat > now + CLOCK_SKEW_SECONDS

      payload
    rescue ArgumentError, JSON::ParserError
      nil
    end

    # One-time use: a replayed ticket (same `jti`) is rejected while the
    # original is still valid. SET NX EX is atomic, so two parallel iframes
    # cannot both redeem the same ticket. If Redis is unreachable the request
    # is allowed: the 60s window is the primary control.
    def consume_ticket(payload)
      Redis::Alfred.set(
        "erp_sso_ticket:#{payload['jti']}", '1',
        nx: true, ex: TICKET_TTL_SECONDS
      )
    rescue StandardError => e
      Rails.logger.warn("[erp-sso] replay guard unavailable: #{e.class}: #{e.message}")
      true
    end

    # Reuses the OIDC user resolver: same email matching, same JIT provisioning
    # into OPENID_CONNECT_JIT_ACCOUNT_ID, so ERP and SSO users stay identical.
    def auth_hash_from(payload)
      {
        'provider' => 'erp_sso',
        'uid' => payload['sub'].presence || payload['email'],
        'info' => {
          'email' => payload['email'],
          'name' => payload['name'].presence,
          'image' => payload['avatarUrl'].presence
        }
      }
    end

    def login_url_for(user, payload)
      query = {
        email: ERB::Util.url_encode(user.email),
        sso_auth_token: user.generate_sso_auth_token,
        ssoAccountId: payload['acc'].presence,
        ssoConversationId: payload['conv'].presence,
        locale: payload['loc'].presence
      }.merge(embed_params).compact

      "#{frontend_url}/app/login?#{query.to_query}"
    end

    def embed_params
      EMBED_PARAMS.each_with_object({}) do |(key, allowed), acc|
        value = params[key]
        acc[key.to_sym] = value if value.present? && allowed.include?(value)
      end
    end

    def login_error_url(error)
      "#{frontend_url}/app/login?error=#{ERB::Util.url_encode(error)}"
    end

    def frontend_url
      ENV.fetch('FRONTEND_URL', 'http://localhost:3000').chomp('/')
    end
  end
end
