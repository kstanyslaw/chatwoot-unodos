# frozen_string_literal: true

require 'rails_helper'

# ERP (Malibu) iframe SSO hand-off. The ticket format is mirrored from
# apps/api-gateway/src/integrations/integrations.service.ts — keep both in sync.
RSpec.describe 'ERP iframe SSO hand-off', type: :request do
  let(:secret) { 'erp-test-secret' }
  let(:frontend_url) { 'https://chat.example.test' }
  let(:email) { 'erp-agent@tripwave.cloud' }
  let(:payload) do
    now = Time.current.to_i
    {
      'sub' => 'erp-user-1',
      'email' => email,
      'name' => 'ERP Agent',
      'avatarUrl' => nil,
      'acc' => '1',
      'conv' => nil,
      'loc' => nil,
      'jti' => SecureRandom.uuid,
      'iat' => now,
      'exp' => now + 60
    }
  end

  def ticket_for(body, signing_secret: secret)
    encoded = Base64.urlsafe_encode64(body.to_json, padding: false)
    signing_input = "v1.#{encoded}"
    "#{signing_input}.#{OpenSSL::HMAC.hexdigest('SHA256', signing_secret, signing_input)}"
  end

  def with_erp_env(erp_secret: secret, &)
    with_modified_env(CHATWOOT_ERP_SSO_SECRET: erp_secret, FRONTEND_URL: frontend_url, &)
  end

  before { create(:user, email: email, name: 'ERP Agent') }

  it 'answers 404 when the ERP secret is not configured' do
    with_erp_env(erp_secret: nil) do
      get '/erp/sso', params: { ticket: ticket_for(payload) }

      expect(response).to have_http_status(:not_found)
    end
  end

  it 'rejects a missing ticket' do
    with_erp_env do
      get '/erp/sso'

      expect(response).to have_http_status(:unauthorized)
    end
  end

  it 'rejects a ticket signed with another secret' do
    with_erp_env do
      get '/erp/sso', params: { ticket: ticket_for(payload, signing_secret: 'wrong') }

      expect(response).to have_http_status(:unauthorized)
    end
  end

  it 'rejects a tampered payload' do
    with_erp_env do
      version, _body, signature = ticket_for(payload).split('.')
      forged = payload.merge('email' => 'attacker@evil.test')
      forged_body = Base64.urlsafe_encode64(forged.to_json, padding: false)

      get '/erp/sso', params: { ticket: "#{version}.#{forged_body}.#{signature}" }

      expect(response).to have_http_status(:unauthorized)
    end
  end

  it 'rejects an expired ticket' do
    with_erp_env do
      get '/erp/sso', params: { ticket: ticket_for(payload.merge('exp' => Time.current.to_i - 5)) }

      expect(response).to have_http_status(:unauthorized)
    end
  end

  it 'rejects a ticket that claims an excessive lifetime' do
    with_erp_env do
      now = Time.current.to_i
      ticket = ticket_for(payload.merge('iat' => now, 'exp' => now + 3_600))

      get '/erp/sso', params: { ticket: ticket }

      expect(response).to have_http_status(:unauthorized)
    end
  end

  it 'signs a known agent in through the sso_auth_token login page' do
    with_erp_env do
      get '/erp/sso', params: { ticket: ticket_for(payload) }

      expect(response).to have_http_status(:found)
      expect(response.location).to start_with("#{frontend_url}/app/login?")
      expect(response.location).to include('sso_auth_token=')
      expect(response.location).to include('ssoAccountId=1')
    end
  end

  it 'forwards the sanitised embed flags to the login page' do
    with_erp_env do
      get '/erp/sso', params: { ticket: ticket_for(payload), erp_embed: '1', erp_theme: 'dark' }

      expect(response).to have_http_status(:found)
      expect(response.location).to include('erp_embed=1')
      expect(response.location).to include('erp_theme=dark')
    end
  end

  it 'drops embed flags with unexpected values' do
    with_erp_env do
      get '/erp/sso', params: { ticket: ticket_for(payload), erp_embed: '1', erp_theme: 'javascript:alert(1)' }

      expect(response).to have_http_status(:found)
      expect(response.location).not_to include('erp_theme=')
    end
  end

  it 'rejects a second redemption of the same ticket' do
    with_erp_env do
      ticket = ticket_for(payload)

      get '/erp/sso', params: { ticket: ticket }
      expect(response).to have_http_status(:found)

      get '/erp/sso', params: { ticket: ticket }
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
