class BillsController < ApplicationController
  def index
    @family = Current.family

    # `bills` filters to active outflows (excludes income) in SQL; group the
    # rest by status in Ruby.
    bills = @family.recurring_transactions
                   .bills
                   .accessible_by(Current.user)
                   .includes(:merchant, :account)

    grouped = bills.group_by { |bill| bill.bill_status(reminder_days: @family.bill_reminder_days_before) }

    @overdue  = (grouped[:overdue] || []).sort_by(&:due_date)
    @due_soon = (grouped[:due_soon] || []).sort_by(&:due_date)
    @upcoming = (grouped[:upcoming] || []).sort_by(&:due_date)

    # Bills is a top-level nav entry, not a Plan subpage, so the trail is
    # Home > Bills (not Home > Plan > Bills).
    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("bills.index.title"), nil ] ]
  end

  def mark_paid
    # Scope to `bills` so a non-bill id (e.g. income) 404s rather than being
    # silently advanced.
    bill = Current.family.recurring_transactions.bills.accessible_by(Current.user).find(params[:id])
    bill.mark_paid!

    redirect_to bills_path, notice: t("bills.marked_paid", name: bill.merchant&.name || bill.name)
  end

  def update_settings
    Current.family.update!(bill_settings_params)
    redirect_to bills_path, notice: t("bills.settings_updated")
  rescue ActiveRecord::RecordInvalid
    # e.g. a crafted out-of-range bill_reminder_days_before (the UI only
    # offers 1..14). Surface a friendly alert instead of a 500.
    redirect_to bills_path, alert: t("bills.settings_invalid")
  end

  private
    def bill_settings_params
      params.require(:family).permit(:bill_reminders_enabled, :bill_reminder_days_before)
    end
end
