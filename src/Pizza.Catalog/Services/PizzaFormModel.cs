using System.ComponentModel.DataAnnotations;
using Pizza.Contracts;

namespace Pizza.Catalog.Services;

public sealed class PizzaFormModel : IValidatableObject
{
    public string Name { get; set; } = "";
    public string Description { get; set; } = "";
    public decimal Price { get; set; } = 10;
    public bool IsAvailable { get; set; } = true;

    public PizzaUpsertRequest ToRequest() => new(Name, Description, Price, IsAvailable);

    public IEnumerable<ValidationResult> Validate(ValidationContext validationContext)
    {
        try
        {
            PizzaCatalogService.Validate(ToRequest());
        }
        catch (CatalogValidationException exception)
        {
            return [new ValidationResult(exception.Message)];
        }

        return [];
    }
}
