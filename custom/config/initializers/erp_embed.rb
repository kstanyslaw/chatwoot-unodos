# frozen_string_literal: true

# Uno Dos Cloud fork — ERP embed bridge (see custom/app/views/custom/_erp_embed.html.erb).
#
# The bridge lives outside core paths so upstream merges stay trivial: the layout
# only renders `custom/erp_embed`, and this initializer makes `custom/app/views`
# discoverable. Everything is gated on ERP_EMBED_ALLOWED_ORIGINS: unset means
# zero behaviour change (the layout skips the partial entirely).
if ENV['ERP_EMBED_ALLOWED_ORIGINS'].present?
  Rails.application.config.after_initialize do
    ApplicationController.prepend_view_path(Rails.root.join('custom/app/views'))
    ActionController::Base.prepend_view_path(Rails.root.join('custom/app/views'))
  end
end
