# Analisi statica di PowerShell: tutte le regole del modulo tranne quelle che il codice di oggi gia' viola.
# Una regola rossa dal primo giorno viene spenta da chi la trova fastidiosa, quindi qui si attiva solo cio' che e'
# verde; le regole escluse sono elencate (col numero di violazioni al 25/11/2026) nella descrizione della PR che
# ha introdotto questo file. Per riattivarne una: sistemare il codice, poi togliere la riga da ExcludeRules.
# La versione del modulo e' fissata in ci/Invoke-PrValidation.ps1: una versione nuova puo' portare regole nuove.
@{
    Severity     = @('Error', 'Warning', 'Information')
    ExcludeRules = @(
        'PSAvoidGlobalVars'                                   # 1359
        'PSAvoidUsingPositionalParameters'                    # 1015
        'PSProvideCommentHelp'                                # 285
        'PSReviewUnusedParameter'                             # 198
        'PSUseShouldProcessForStateChangingFunctions'         # 137
        'PSUseOutputTypeCorrectly'                            # 114
        'PSUseApprovedVerbs'                                  # 41
        'PSAvoidUsingWriteHost'                               # 37
        'PSAvoidUsingEmptyCatchBlock'                         # 23
        'PSUseBOMForUnicodeEncodedFile'                       # 21
        'PSUseSingularNouns'                                  # 10
        'PSUseDeclaredVarsMoreThanAssignments'                # 9
        'PSUseLiteralInitializerForHashtable'                 # 9
        'PSAvoidOverwritingBuiltInCmdlets'                    # 3
        'PSUseUsingScopeModifierInNewRunspaces'               # 3
        'PSAvoidUsingConvertToSecureStringWithPlainText'      # 1
    )
}
