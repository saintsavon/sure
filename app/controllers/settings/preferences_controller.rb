class Settings::PreferencesController < ApplicationController
  layout "settings"

  def show
    @user = Current.user
  end

  # Writes per-user boolean preferences stored in the JSONB `users.preferences`
  # column. Mirrors Settings::AppearancesController#update so the toggle card on
  # the Preferences page can submit directly without going through the broader
  # UsersController#update flow (which expects a full user form payload).
  def update
    @user = Current.user
    user_params = params.permit(user: [ :preview_features_enabled ]).fetch(:user, {})
    family_params = params.permit(family: [ :budget_rollover_enabled ]).fetch(:family, {})

    @user.transaction do
      @user.lock!
      updated_prefs = (@user.preferences || {}).deep_dup
      if user_params.key?(:preview_features_enabled)
        updated_prefs["preview_features_enabled"] =
          ActiveModel::Type::Boolean.new.cast(user_params[:preview_features_enabled])
      end
      @user.update!(preferences: updated_prefs)
    end

    # Family-wide (not per-user), so it's a separate update rather than part
    # of the JSONB preferences blob above -- same toggle-card submit pattern,
    # different backing record.
    if family_params.key?(:budget_rollover_enabled)
      Current.family.update!(
        budget_rollover_enabled: ActiveModel::Type::Boolean.new.cast(family_params[:budget_rollover_enabled])
      )
    end

    redirect_to settings_preferences_path
  end
end
