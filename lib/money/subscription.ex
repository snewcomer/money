defmodule Money.Subscription do
  @moduledoc """
  Provides functions to upgrade and downgrade subscriptions
  from one plan to another.

  Since moving from one plan to another may require
  prorating the payment stream at the point of transition,
  this module is introduced to provide a single point of
  calculation of the proration in order to give clear focus
  to the issues of calculating the carry-over amount or
  the carry-over period at the point of plan change.

  ### Changing a subscription plan

  Changing a subscription plan requires the following
  information be provided:

  * The definition of the current plan
  * The definition of the new plan
  * The last billing date
  * The strategy for changing the plan which is either:
    * to have the effective date of the new plan be after
      the current billing period of the current plan
    * To change the plan immediately in which case there will
      be a credit on the current plan which needs to be applied
      to the new plan.

  See `Money.Subscription.change/4`

  ### When the new plan is effective at the end of the current billing period

  The first strategy simply finishes the current billing period before
  the new plan is introduced and therefore no proration is required.
  This is the default strategy.

  ### When the new plan is effective immediately

  If the new plan is to be effective immediately then any credit
  balance remaining on the old plan needs to be applied to the
  new plan.  There are two options of applying the credit:

  1. Reduce the billing amount of the first period of the new plan
     be the amount of the credit left on the old plan. This means
     that the billing amount for the first period of the new plan
     will be different (less) than the billing amount for subsequent
     periods on the new plan.

  2. Extend the first period of the new plan by the interval amount
     that can be funded by the credit amount left on the old plan. In
     the situation where the credit amount does not fully fund an integral
     interval the additional interval can be truncated or rounded up to the next
     integral period.

  ### Plan definition

  This module, and `Money` in general, does not provide a full
  billing or subscription solution - its focus is to support a reliable
  means of calcuating the accounting outcome of a plan change only.
  Therefore the plan definition required by `Money.Subscription` can be
  any `Map.t` that includes the following fields:

  * `interval` which defines the billing interval for a plan. The value
    can be one of `day`, `week`, `month` or `year`.

  * `interval_count` which defines the number of `interval`s for the
    billing period.  This must be a positive integer.

  * `price` which is a `Money.t` representing the price of the plan
    to be paid each billing period.

  ### Billing in advance

  This module calculates all subscription changes on the basis
  that billing is done in advance.  This primarily affects the
  calculation of plan credit when a plan changes.  The assumption
  is that the period from the start of the plan to the point
  of change has been consumed and therefore the credit is based
  upon that period of the plan that has not yet been consumed.

  If the calculation was based upon "payment in arrears" then
  the credit would actually be a debit since the part of the
  current period consumed has not yet been paid for.

  """

  alias Money.Subscription.{Change, Plan}

  @type id :: term()
  @type t :: %{id: id(), previous_billing_date: DateTime.t(), plans: list(Plant.t())}

  defstruct id: nil,
            previous_billing_date: nil,
            next_billing_date: nil,
            plans: [],
            created_at: nil

  @doc """
  * `:id` an id for the subscription
  * `:plan` the initial plan
  * `:effective_date` the effective date of the plan which
    is the start of the billing period
  """
  def new(options \\ []) do
    options =
      default_subscription_options()
      |> Keyword.merge(options)

    struct(__MODULE__, options)
    |> Map.put(:plans, {options[:effective_date], options[:plan]})
  end

  defp default_subscription_options do
    [
      created_at: DateTime.utc_now()
    ]
  end

  @doc """
  Change plan from the current plan to a new plan.

  ## Arguments

  * `current_plan` is a map with at least the fields `interval`, `interval_count` and `price`
  * `new_plan` is a map with at least the fields `interval`, `interval_count` and `price`
  * `previous_billing_date` is a `Date.t` or other map with the fields `year`, `month`,
    `day` and `calendar`
  * `options` is a keyword map of options the define how the change is to be made

  ## Options

  * `:effective` defines when the new plan comes into effect.  The values are `:immediately`,
    a `Date.t` or `:next_period`.  The default is `:next_period`.  Note that the date
    applied in the case of `:immediately` is the date returned by `Date.utc_today`.

  * `:prorate` which determines how to prorate the current plan into the new plan.  The
    options are `:price` which will reduce the price of the first period of the new plan
    by the credit amount left on the old plan (this is the default). Or `:period` in which
    case the first period of the new plan is extended by the `interval` amount of the new
    plan that the credit on the old plan will fund.

  * `:round` determines whether when prorating the `:period` it is truncated or rounded up
    to the next nearest full `interval_count`. Valid values are `:down`, `:half_up`,
    `:half_even`, `:ceiling`, `:floor`, `:half_down`, `:up`.  The default is `:up`.

  ## Returns

  A `Money.Subscription.Change.t` with the following elements:

  * `:next_billing_date` which is the next billing date derived from the option
    `:effective` given to `change/4`

  * `:next_billing_amount` is the amount to be billed, net of any credit, at
    the `:next_billing_date`

  * `:following_billing_date` is the the billing date after the `:next_billing_date`
    including any `credit_days_applied`

  * `:credit_amount` is the amount of unconsumed credit of the current plan

  * `:credit_amount_applied` is the amount of credit applied to the new plan. If
    the `:prorate` option is `:price` (the default) the next `:next_billing_amount`
    is the plan `:price` reduced by the `:credit_amount_applied`. If the `:prorate`
    option is `:period` then the `:next_billing_amount` is not adjusted.  In this
    case the `:following_billing_date` is extended by the `:credit-days_applied`
    instead.

  * `:credit_days_applied` is the number of days credit applied to the next billing
    by adding days to the `:following_billing_date`.

  * `:credit_period_ends` is the date on which any applied credit is consumed or `nil`

  * `:carry_forward` is any amount of credit carried forward to a subsequent period.
    If non-zero this amount is a negative `Money.t`. It is non-zero when the credit
    amount for the current plan is greater than the price of the new plan.  In
    this case the `:next_billing_amount` is zero.

  ## Examples

      # Change at end of the current period so no proration
      iex> current = Money.Subscription.Plan.new!(Money.new(:USD, 10), :month, 1)
      iex> new = Money.Subscription.Plan.new!(Money.new(:USD, 10), :month, 3)
      iex> Money.Subscription.change_plan current, new, previous_billing_date: ~D[2018-01-01]
      %Money.Subscription.Change{
        carry_forward: Money.zero(:USD),
        credit_amount: Money.zero(:USD),
        credit_amount_applied: Money.zero(:USD),
        credit_days_applied: 0,
        credit_period_ends: nil,
        following_billing_date: ~D[2018-03-01],
        next_billing_amount: Money.new(:USD, 10),
        next_billing_date: ~D[2018-02-01]
      }

      # Change during the current plan generates a credit amount
      iex> current = Money.Subscription.Plan.new!(Money.new(:USD, 10), :month, 1)
      iex> new = Money.Subscription.Plan.new!(Money.new(:USD, 10), :month, 3)
      iex> Money.Subscription.change_plan current, new, previous_billing_date: ~D[2018-01-01], effective: ~D[2018-01-15]
      %Money.Subscription.Change{
        carry_forward: Money.zero(:USD),
        credit_amount: Money.new(:USD, "5.49"),
        credit_amount_applied: Money.new(:USD, "5.49"),
        credit_days_applied: 0,
        credit_period_ends: nil,
        following_billing_date: ~D[2018-04-15],
        next_billing_amount: Money.new(:USD, "4.51"),
        next_billing_date: ~D[2018-01-15]
      }

      # Change during the current plan generates a credit period
      iex> current = Money.Subscription.Plan.new!(Money.new(:USD, 10), :month, 1)
      iex> new = Money.Subscription.Plan.new!(Money.new(:USD, 10), :month, 3)
      iex> Money.Subscription.change_plan current, new, previous_billing_date: ~D[2018-01-01], effective: ~D[2018-01-15], prorate: :period
      %Money.Subscription.Change{
        carry_forward: Money.zero(:USD),
        credit_amount: Money.new(:USD, "5.49"),
        credit_amount_applied: Money.zero(:USD),
        credit_days_applied: 50,
        credit_period_ends: ~D[2018-03-05],
        following_billing_date: ~D[2018-06-04],
        next_billing_amount: Money.new(:USD, 10),
        next_billing_date: ~D[2018-01-15]
      }

  """
  @spec change_plan(
          subscription_or_plan :: __MODULE__.t() | Plan.t(),
          new_plan :: Map.t(),
          options :: Keyword.t()
        ) :: Map.t()
  def change_plan(subscription_or_plan, new_plan, options \\ [])

  def change_plan(
        %{plans: [{current_start_date, %{price: %Money{currency: currency}} = current_plan} | _]} =
          subscription,
        %{price: %Money{currency: currency}} = new_plan,
        options
      ) do
    options =
      options_from(options, default_options())
      |> Keyword.put_new(:current_start_date, current_start_date)
      |> Keyword.put_new(:previous_billing_date, subscription.previous_billing_date)

    change_plan(current_plan, new_plan, options[:effective], options)
  end

  def change_plan(
        %{price: %Money{currency: currency}} = current_plan,
        %{price: %Money{currency: currency}} = new_plan,
        options
      ) do
    options = options_from(options, default_options())
    change_plan(current_plan, new_plan, options[:effective], options)
  end

  # Change the plan at the end of the current billing period.  This requires
  # no proration and is therefore the easiest to calculate.
  defp change_plan(current_plan, new_plan, :next_period, options) do
    price = Map.get(new_plan, :price)
    next_billing_date = next_billing_date(current_plan, options[:previous_billing_date])
    zero = Money.zero(price.currency)

    %Change{
      next_billing_amount: price,
      next_billing_date: next_billing_date,
      following_billing_date: next_billing_date(current_plan, next_billing_date),
      credit_amount_applied: zero,
      credit_amount: zero,
      credit_days_applied: 0,
      credit_period_ends: nil,
      carry_forward: zero
    }
  end

  defp change_plan(current_plan, new_plan, :immediately, options) do
    change_plan(current_plan, new_plan, Date.utc_today(), options)
  end

  defp change_plan(current_plan, new_plan, effective_date, options) do
    credit = plan_credit(current_plan, effective_date, options)
    prorate(new_plan, credit, effective_date, options[:prorate], options)
  end

  # Reduce the price of the first period of the new plan by the
  # credit amount on the current plan
  defp prorate(plan, credit_amount, effective_date, :price, options) do
    prorate_price =
      Map.get(plan, :price)
      |> Money.sub!(credit_amount)
      |> Money.round(rounding_mode: options[:round])

    zero = zero(plan)

    {next_billing_amount, carry_forward} =
      if Money.cmp(prorate_price, zero) == :lt do
        {zero, prorate_price}
      else
        {prorate_price, zero}
      end

    %Change{
      next_billing_date: effective_date,
      next_billing_amount: next_billing_amount,
      following_billing_date: next_billing_date(plan, effective_date),
      credit_amount: credit_amount,
      credit_amount_applied: Money.add!(credit_amount, carry_forward),
      credit_days_applied: 0,
      credit_period_ends: nil,
      carry_forward: carry_forward
    }
  end

  # Extend the first period of the new plan by the amount of credit
  # on the current plan
  defp prorate(plan, credit_amount, effective_date, :period, options) do
    {following_billing_date, days_credit} =
      extend_period(plan, credit_amount, effective_date, options)

    next_billing_amount = Map.get(plan, :price)
    credit_period_ends = Date.add(effective_date, days_credit - 1)

    %Change{
      next_billing_date: effective_date,
      next_billing_amount: next_billing_amount,
      following_billing_date: following_billing_date,
      credit_amount: credit_amount,
      credit_amount_applied: zero(plan),
      credit_days_applied: days_credit,
      credit_period_ends: credit_period_ends,
      carry_forward: zero(plan)
    }
  end

  defp plan_credit(%{price: price} = plan, effective_date, options) do
    plan_days = plan_days(plan, effective_date)
    price_per_day = Decimal.div(price.amount, Decimal.new(plan_days))
    days_remaining = days_remaining(plan, options[:previous_billing_date], effective_date)

    price_per_day
    |> Decimal.mult(Decimal.new(days_remaining))
    |> Money.new(price.currency)
    |> Money.round(rounding_mode: options[:round])
  end

  # Extend the billing period by the amount that
  # credit will fund on the new plan in days.
  defp extend_period(plan, credit, effective_date, options) do
    price = Map.get(plan, :price)
    plan_days = plan_days(plan, effective_date)
    price_per_day = Decimal.div(price.amount, Decimal.new(plan_days))

    credit_days_applied =
      credit.amount
      |> Decimal.div(price_per_day)
      |> Decimal.round(0, options[:round])
      |> Decimal.to_integer()

    following_billing_date =
      next_billing_date(plan, effective_date)
      |> Date.add(credit_days_applied)

    {following_billing_date, credit_days_applied}
  end

  @doc """
  Returns number of days in the plan period

  ## Arguments

  * `plan` is any `Money.Subscription.Plan.t`

  * `previous_billing_date` is a `Date.t`

  ## Returns

  The number of days in the billing period

  ## Examples

      iex> plan = Money.Subscription.Plan.new! Money.new!(:USD, 100), :month, 1
      iex> Money.Subscription.plan_days plan, ~D[2018-01-01]
      31
      iex> Money.Subscription.plan_days plan, ~D[2018-02-01]
      28
      iex> Money.Subscription.plan_days plan, ~D[2018-04-01]
      30

  """
  @spec days_remaining(Plan.t(), Date.t()) :: integer
  def plan_days(plan, previous_billing_date) do
    plan
    |> next_billing_date(previous_billing_date)
    |> Date.diff(previous_billing_date)
  end

  @doc """
  Returns number of days remaining in the plan period

  ## Arguments

  * `plan` is any `Money.Subscription.Plan.t`

  * `previous_billing_date` is a `Date.t`

  * `effective_date` is a `Date.t` after the
    `previous_billing_date` and before the end of
    the `plan_days`

  ## Returns

  The number of days remaining in the billing period

  ## Examples

      iex> plan = Money.Subscription.Plan.new! Money.new!(:USD, 100), :month, 1
      iex> Money.Subscription.days_remaining plan, ~D[2018-01-01], ~D[2018-01-02]
      30
      iex> Money.Subscription.days_remaining plan, ~D[2018-02-01], ~D[2018-02-02]
      27

  """
  @spec days_remaining(Plan.t(), Date.t(), Date.t()) :: integer
  def days_remaining(plan, previous_billing_date, effective_date \\ Date.utc_today()) do
    plan
    |> next_billing_date(previous_billing_date)
    |> Date.diff(effective_date)
  end

  @doc """
  Returns the next billing date for a plan

  ## Arguments

  * `plan` is a `Money.Subscription.Plan.t`

  * `previous_billing_date` is the date of the last bill that
    represents the start of the billing period

  ## Returns

  The next billing date as a `Date.t`.

  ## Example

      iex> plan = Money.Subscription.Plan.new!(Money.new!(:USD, 100), :month)
      iex> Money.Subscription.next_billing_date(plan, ~D[2018-03-01])
      ~D[2018-04-01]

      iex> plan = Money.Subscription.Plan.new!(Money.new!(:USD, 100), :day, 30)
      iex> Money.Subscription.next_billing_date(plan, ~D[2018-02-01])
      ~D[2018-03-03]

  """
  @spec next_billing_date(Plan.t(), Date.t()) :: Date.t()
  def next_billing_date(%{interval: :day, interval_count: count}, %{
        year: year,
        month: month,
        day: day,
        calendar: calendar
      }) do
    {year, month, day} =
      (calendar.date_to_iso_days(year, month, day) + count)
      |> calendar.date_from_iso_days

    {:ok, date} = Date.new(year, month, day, calendar)
    date
  end

  def next_billing_date(%{interval: :week, interval_count: count}, previous_billing_date) do
    next_billing_date(%{interval: :day, interval_count: count * 7}, previous_billing_date)
  end

  def next_billing_date(
        %{interval: :month, interval_count: count} = plan,
        %{year: year, month: month, day: day, calendar: calendar} = previous_billing_date
      ) do
    months_in_this_year = months_in_year(previous_billing_date)

    {year, month} =
      if count + month <= months_in_this_year do
        {year, month + count}
      else
        months_left_this_year = months_in_this_year - month
        plan = %{plan | interval_count: count - months_left_this_year - 1}
        previous_billing_date = %{previous_billing_date | year: year + 1, month: 1, day: day}
        date = next_billing_date(plan, previous_billing_date)
        {Map.get(date, :year), Map.get(date, :month)}
      end

    day =
      year
      |> calendar.days_in_month(month)
      |> min(day)

    {:ok, next_billing_date} = Date.new(year, month, day, calendar)
    next_billing_date
  end

  def next_billing_date(
        %{interval: :year, interval_count: count},
        %{year: year} = previous_billing_date
      ) do
    %{previous_billing_date | year: year + count}
  end

  ## Helpers

  defp months_in_year(%{year: year, calendar: calendar}) do
    if function_exported?(calendar, :months_in_year, 1) do
      calendar.months_in_year(year)
    else
      12
    end
  end

  defp options_from(options, default_options) do
    default_options
    |> Keyword.merge(options)
    |> Enum.into(%{})
  end

  defp default_options do
    [effective: :next_period, prorate: :price, round: :up]
  end

  defp zero(plan) do
    plan
    |> Map.get(:price)
    |> Map.get(:currency)
    |> Money.zero()
  end
end